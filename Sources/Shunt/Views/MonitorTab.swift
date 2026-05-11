import SwiftUI

struct MonitorTab: View {
    @ObservedObject private var monitor = AppServices.shared.flowMonitor
    @State private var viewMode: ViewMode = .connections
    @State private var autoScroll = true   // events mode only
    @Environment(\.shuntTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    /// Tick that drives the "age" labels and active-state fades in the
    /// connections view, so rows update even when no new events arrive.
    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    enum ViewMode: String, Hashable, CaseIterable {
        case connections, events
        var title: String {
            switch self {
            case .connections: return "Connections"
            case .events:      return "Events"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            controls
            if let err = monitor.lastError {
                Text(err)
                    .font(.shuntCaption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 8)
            }
            switch viewMode {
            case .connections: connectionsList
            case .events:      eventsList
            }
        }
        // FlowMonitor is started by AppDelegate for the lifetime of the app
        // (the menubar popover also reads it), so MonitorTab doesn't manage
        // its own start/stop anymore.
        .onAppear { monitor.start() }
        .onReceive(clock) { now = $0 }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Monitor")
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.65)
                .foregroundStyle(.white)
            Text(viewMode == .connections
                 ? "Live connections the extension is routing through the upstream. Newest activity floats to the top."
                 : "Raw event log — one row per claimed flow, in timeline order.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.62))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 14)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 6) {
            // Group 1 — view mode
            Picker("", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 176)

            groupDivider

            // Group 2 — actions
            Button {
                if monitor.isStreaming { monitor.stop() } else { monitor.start() }
            } label: {
                Image(systemName: monitor.isStreaming ? "pause.fill" : "play.fill")
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent(for: scheme))
            .help(monitor.isStreaming ? "Pause stream" : "Resume stream")

            Button {
                monitor.clear()
            } label: {
                Image(systemName: "trash")
                    .frame(width: 14, height: 14)
            }
            .disabled(monitor.connections.isEmpty && monitor.events.isEmpty)
            .help("Clear monitor")

            if viewMode == .events {
                groupDivider

                // Group 3 — view options (Events only)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: $autoScroll)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(theme.accent(for: scheme))
                        .labelsHidden()
                }
                .contentShape(Rectangle())
                .help("Auto-scroll to newest event")
            }

            Spacer(minLength: 8)

            // Group 4 — status
            if monitor.isStreaming {
                Circle()
                    .fill(theme.statusActive(for: scheme))
                    .frame(width: 6, height: 6)
                    .shadow(color: theme.statusActive(for: scheme).opacity(0.5), radius: 3)
                    .contentShape(Rectangle())
                    .help("Streaming live from the extension log")
                    .padding(.trailing, 2)
            }
            HStack(spacing: 4) {
                Image(systemName: countIcon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(countLabel)
                    .font(.shuntMonoLabel)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .help(countLabelLong)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 10)
    }

    /// Thin vertical separator that visually groups controls. 1pt wide, 16pt
    /// tall, system separator color. Matches DESIGN.md §Color separator rule.
    private var groupDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 4)
    }

    private var countIcon: String {
        switch viewMode {
        case .connections: return "dot.radiowaves.right"
        case .events:      return "list.bullet"
        }
    }

    private var countLabel: String {
        switch viewMode {
        case .connections: return "\(monitor.connections.count) conn"
        case .events:      return "\(monitor.events.count) evt"
        }
    }

    private var countLabelLong: String {
        switch viewMode {
        case .connections:
            let n = monitor.connections.count
            return "\(n) \(n == 1 ? "connection" : "connections")"
        case .events:
            let n = monitor.events.count
            return "\(n) \(n == 1 ? "event" : "events")"
        }
    }

    // MARK: - Connections (Little-Snitch-style)

    private var connectionsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if monitor.connections.isEmpty {
                    EmptyMonitorState(
                        streaming: monitor.isStreaming,
                        mode: .connections
                    )
                    .padding(.vertical, 60)
                } else {
                    ForEach(monitor.connectionsSorted) { conn in
                        ConnectionRow(
                            conn: conn,
                            now: now,
                            theme: theme,
                            scheme: scheme
                        )
                        .id(conn.id)
                        Divider().padding(.leading, 34)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: monitor.connectionsSorted.map(\.id))
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .padding(.horizontal, 28)
        .padding(.bottom, 28)
    }

    // MARK: - Events (timeline)

    private var eventsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if monitor.events.isEmpty {
                        EmptyMonitorState(
                            streaming: monitor.isStreaming,
                            mode: .events
                        )
                        .padding(.vertical, 60)
                    } else {
                        ForEach(monitor.events) { event in
                            EventRow(event: event, theme: theme, scheme: scheme)
                                .id(event.id)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
            .onChange(of: monitor.events.count) { _, _ in
                guard autoScroll, let last = monitor.events.last else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Connection row

private struct ConnectionRow: View {
    let conn: FlowMonitor.ConnectionSummary
    let now: Date
    let theme: ShuntTheme
    let scheme: ColorScheme

    var body: some View {
        HStack(spacing: 12) {
            ActivityDot(
                isActive: conn.isActive(at: now),
                accent: theme.statusActive(for: scheme)
            )
            .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(conn.bundleID)
                    .font(.shuntMonoData)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(conn.host):\(conn.port)")
                    .font(.shuntMonoData)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            // Only show endpoint IP if it adds info (i.e. host is a hostname,
            // not the same IP literal — otherwise we'd be repeating ourselves).
            if let ip = conn.endpointIP, ip != conn.host {
                Text(ip)
                    .font(.shuntMonoLabel)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: 110, alignment: .trailing)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text("×\(conn.count)")
                    .font(.shuntMonoLabel)
                    .foregroundStyle(.secondary)
                Text(ageLabel)
                    .font(.shuntMonoLabel)
                    .foregroundStyle(conn.isActive(at: now) ? theme.statusActive(for: scheme) : .secondary)
            }
            .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var ageLabel: String {
        if conn.isActive(at: now) { return "now" }
        let s = Int(now.timeIntervalSince(conn.lastSeen))
        if s < 60    { return "\(s)s" }
        if s < 3600  { return "\(s/60)m" }
        return "\(s/3600)h"
    }
}

private struct ActivityDot: View {
    let isActive: Bool
    let accent: Color

    var body: some View {
        Circle()
            .fill(isActive ? accent : Color.secondary.opacity(0.25))
            .shadow(color: isActive ? accent.opacity(0.55) : .clear, radius: 3)
    }
}

// MARK: - Event row (timeline)

private struct EventRow: View {
    let event: FlowMonitor.FlowEvent
    let theme: ShuntTheme
    let scheme: ColorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(timeString)
                .font(.shuntMonoData)
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.bundleID)
                    .font(.shuntMonoData)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(event.host):\(event.port)")
                    .font(.shuntMonoData)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if let ip = event.endpointIP, ip != event.host {
                Text(ip)
                    .font(.shuntMonoLabel)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: 110, alignment: .trailing)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Text("route")
                .font(.shuntMonoLabel)
                .kerning(0.6)
                .foregroundStyle(theme.accent(for: scheme))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(theme.accent(for: scheme).opacity(0.12)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: event.timestamp)
    }
}

// MARK: - Empty state

private struct EmptyMonitorState: View {
    let streaming: Bool
    let mode: MonitorTab.ViewMode

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: streaming ? "waveform" : "waveform.slash")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(streaming ? "Waiting for flows…" : "Monitor paused")
                .font(.shuntLabelStrong)
                .foregroundStyle(.secondary)
            Text(hint)
                .font(.shuntCaption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
    }

    private var hint: String {
        if !streaming { return "Click Stream to resume reading the extension log." }
        switch mode {
        case .connections:
            return "Use an app whose bundle ID matches one of your rules. Live connections will appear here, newest at the top."
        case .events:
            return "Each claimed flow becomes one row here in the order it arrives."
        }
    }
}
