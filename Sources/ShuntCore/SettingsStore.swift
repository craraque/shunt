import Foundation

/// Persists `ShuntSettings` as JSON. The main app uses the App Group container
/// (readable/writable by the user) so the settings survive app restarts and can
/// be inspected / backed up. The system extension receives the same JSON
/// via `NETunnelProviderProtocol.providerConfiguration` — it does NOT read the
/// container directly because the extension runs as root and its home
/// directory (`/var/root`) resolves to a different Group Container than the
/// user's.
public final class SettingsStore {
    public static let appGroup = "group.com.craraque.shunt"
    public static let providerConfigKey = "shuntSettings"
    private static let fileName = "settings.v1.json"

    /// Darwin notification posted by the main app after a successful
    /// `saveToPreferences()` so the running system extension can re-read
    /// its `protocolConfiguration` and swap rules in-memory without a
    /// tunnel restart. We use Darwin notifications because Apple's
    /// `NETunnelProviderSession.sendProviderMessage()` silently drops
    /// messages destined for `NETransparentProxyProvider` on current
    /// macOS — the SE never receives `handleAppMessage`.
    public static let applyRulesDarwinNotification = "com.craraque.shunt.applyRules"

    public enum Error: Swift.Error {
        case containerUnavailable
    }

    public init() {}

    public func load() -> ShuntSettings {
        guard let url = try? fileURL() else { return .empty }
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return (try? JSONDecoder().decode(ShuntSettings.self, from: data)) ?? .empty
    }

    public func save(_ settings: ShuntSettings) throws {
        let url = try fileURL()
        let data = try JSONEncoder().encode(settings)
        try data.write(to: url, options: [.atomic])
    }

    public func exportJSON(_ settings: ShuntSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(settings)
    }

    public func importJSON(_ data: Data) throws -> ShuntSettings {
        try JSONDecoder().decode(ShuntSettings.self, from: data)
    }

    public func fileURL() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroup
        ) else {
            throw Error.containerUnavailable
        }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container.appendingPathComponent(Self.fileName)
    }

    /// Encode settings into the form we hand to `NETunnelProviderProtocol.providerConfiguration`.
    public static func encodeForProvider(_ settings: ShuntSettings) throws -> [String: Any] {
        let data = try JSONEncoder().encode(settings)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return [providerConfigKey: json]
    }

    /// Decode settings from the NE provider configuration dictionary.
    public static func decodeFromProvider(_ dict: [String: Any]?) -> ShuntSettings {
        guard let json = dict?[providerConfigKey] as? String,
              let data = json.data(using: .utf8),
              let settings = try? JSONDecoder().decode(ShuntSettings.self, from: data) else {
            return .empty
        }
        return settings
    }
}
