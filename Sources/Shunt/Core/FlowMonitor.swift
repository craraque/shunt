import Foundation

/// Live stream of claimed flows, read by shelling out to `log stream` and
/// parsing the `CLAIM …` lines the ShuntProxy extension already emits.
///
/// Design choice: using the `log` CLI instead of `OSLogStore` because
/// OSLogStore's `.system` scope requires entitlements that aren't available
/// to Developer-ID-signed apps without a DTS exception. `log stream` is
/// Apple-signed, callable from any user process, and streams in real time.
/// Trade-off: we parse a line format instead of reading structured log data,
/// but the format is stable (ShuntProxyProvider.handleNewFlow owns it).
@MainActor
final class FlowMonitor: ObservableObject {

    struct FlowEvent: Identifiable, Hashable {
        let id: UUID
        let timestamp: Date
        let bundleID: String
        let host: String
        let port: Int
        let endpointIP: String?
    }

    /// Aggregated "connection" — Little-Snitch-style row that de-duplicates
    /// flows to the same `(bundleID, host, port)` destination. Each new event
    /// bumps `lastSeen` and the count, and the view sorts by `lastSeen desc`
    /// so the most-recently-active row floats to the top.
    struct ConnectionSummary: Identifiable, Hashable {
        let id: String          // "\(bundleID)|\(host):\(port)"
        let bundleID: String
        let host: String
        let port: Int
        var endpointIP: String?
        var firstSeen: Date
        var lastSeen: Date
        var count: Int

        /// Active if the most recent event was within the last 2.5 seconds.
        func isActive(at now: Date) -> Bool {
            now.timeIntervalSince(lastSeen) < 2.5
        }
    }

    @Published private(set) var events: [FlowEvent] = []
    @Published private(set) var connections: [String: ConnectionSummary] = [:]
    @Published private(set) var isStreaming = false
    @Published var lastError: String?

    /// Connections sorted by last-seen descending. View layer reads this.
    var connectionsSorted: [ConnectionSummary] {
        connections.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    private var process: Process?
    private var reader: Task<Void, Never>?
    private let maxEvents = 500

    /// Predicate matches any CLAIM log line emitted by the provider subsystem.
    private static let predicate =
        "subsystem == \"com.craraque.shunt.proxy\" AND eventMessage CONTAINS \"CLAIM\""

    /// Regex matching `CLAIM <bundleID> → <host>:<port> (endpoint=<ip>)`.
    private static let claimRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"CLAIM\s+(\S+)\s+→\s+([^:\s]+):(\d+)\s+\(endpoint=([^)]+)\)"#
    )

    func start() {
        guard !isStreaming else { return }
        lastError = nil

        let proc = Process()
        proc.launchPath = "/usr/bin/log"
        proc.arguments = [
            "stream",
            "--style", "ndjson",
            "--predicate", Self.predicate,
            "--info"
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe() // swallow stderr

        do {
            try proc.run()
        } catch {
            lastError = "Couldn't start log stream: \(error.localizedDescription)"
            return
        }

        self.process = proc
        self.isStreaming = true

        let handle = pipe.fileHandleForReading
        self.reader = Task.detached { [weak self] in
            do {
                for try await line in handle.bytes.lines {
                    if Task.isCancelled { break }
                    guard let event = Self.parseEvent(line: line) else { continue }
                    await MainActor.run {
                        self?.append(event)
                    }
                }
            } catch {
                await MainActor.run {
                    self?.lastError = "Log stream ended: \(error.localizedDescription)"
                    self?.isStreaming = false
                }
            }
        }
    }

    func stop() {
        reader?.cancel()
        reader = nil
        process?.terminate()
        process = nil
        isStreaming = false
    }

    func clear() {
        events.removeAll()
        connections.removeAll()
    }

    private func append(_ event: FlowEvent) {
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        upsertConnection(for: event)
    }

    private func upsertConnection(for event: FlowEvent) {
        let key = "\(event.bundleID)|\(event.host):\(event.port)"
        if var existing = connections[key] {
            existing.lastSeen = event.timestamp
            existing.count += 1
            if let ip = event.endpointIP { existing.endpointIP = ip }
            connections[key] = existing
        } else {
            connections[key] = ConnectionSummary(
                id: key,
                bundleID: event.bundleID,
                host: event.host,
                port: event.port,
                endpointIP: event.endpointIP,
                firstSeen: event.timestamp,
                lastSeen: event.timestamp,
                count: 1
            )
            // Evict oldest if we exceed the cap, so memory stays bounded.
            if connections.count > maxConnections {
                if let oldestKey = connections.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
                    connections.removeValue(forKey: oldestKey)
                }
            }
        }
    }

    private let maxConnections = 200

    // MARK: - Parsing

    /// `nonisolated` so the detached reader task can parse off-main without
    /// bouncing every line through the main actor.
    private nonisolated static func parseEvent(line: String) -> FlowEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["eventMessage"] as? String
        else { return nil }

        guard let regex = claimRegex else { return nil }
        let range = NSRange(message.startIndex..., in: message)
        guard let match = regex.firstMatch(in: message, range: range),
              match.numberOfRanges == 5,
              let bRange = Range(match.range(at: 1), in: message),
              let hRange = Range(match.range(at: 2), in: message),
              let pRange = Range(match.range(at: 3), in: message),
              let iRange = Range(match.range(at: 4), in: message),
              let port = Int(message[pRange])
        else { return nil }

        let timestamp = parseLogTimestamp(json["timestamp"] as? String) ?? Date()

        return FlowEvent(
            id: UUID(),
            timestamp: timestamp,
            bundleID: String(message[bRange]),
            host: String(message[hRange]),
            port: port,
            endpointIP: String(message[iRange])
        )
    }

    /// `log stream --style ndjson` emits timestamps as
    /// `"2026-04-22 17:30:00.123456-0700"`. Parse with a few tolerant formats.
    private nonisolated static func parseLogTimestamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        let formats = [
            "yyyy-MM-dd HH:mm:ss.SSSSSSxx",
            "yyyy-MM-dd HH:mm:ss.SSSSSSZ",
            "yyyy-MM-dd HH:mm:ssxx"
        ]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
