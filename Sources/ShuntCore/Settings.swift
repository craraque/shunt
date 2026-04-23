import Foundation

public struct ManagedApp: Codable, Identifiable, Hashable {
    public var id: UUID
    public var bundleID: String
    public var displayName: String
    public var appPath: String?
    public var enabled: Bool

    public init(id: UUID = UUID(), bundleID: String, displayName: String, appPath: String? = nil, enabled: Bool = true) {
        self.id = id
        self.bundleID = bundleID
        self.displayName = displayName
        self.appPath = appPath
        self.enabled = enabled
    }
}

public struct UpstreamProxy: Codable, Hashable {
    public var host: String
    public var port: UInt16
    /// nil = use the host's default routing table. Set to an interface name
    /// (e.g. "bridge100" for Parallels shared network) to bypass NECP scoping
    /// and force traffic out a specific NIC. Required when the proxy lives
    /// on a virtual bridge not reachable via the primary interface.
    public var bindInterface: String?

    public init(host: String = "127.0.0.1", port: UInt16 = 1080, bindInterface: String? = nil) {
        self.host = host
        self.port = port
        self.bindInterface = bindInterface
    }
}

// MARK: - Compound rules (v2)

public struct HostPattern: Codable, Hashable, Identifiable {
    public var id: UUID
    public enum Kind: String, Codable, CaseIterable, Hashable {
        case exact    // "teams.microsoft.com" — exact hostname match (case-insensitive)
        case suffix   // "*.corp.com" — matches "a.b.corp.com" and "corp.com"
        case cidr     // "10.0.0.0/8" — destination IP match (v4 or v6)
    }
    public var kind: Kind
    public var pattern: String

    public init(id: UUID = UUID(), kind: Kind = .suffix, pattern: String = "") {
        self.id = id
        self.kind = kind
        self.pattern = pattern
    }
}

public struct Rule: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    /// Apps that must match for this rule to apply. Empty = any app.
    public var apps: [ManagedApp]
    /// Host patterns that must match for this rule to apply. Empty = any host.
    public var hosts: [HostPattern]
    public enum Action: String, Codable, CaseIterable, Hashable {
        case route   // send the flow through the upstream proxy
        case direct  // pass through to host network (override a broader route rule)
    }
    public var action: Action

    public init(id: UUID = UUID(), name: String, enabled: Bool = true,
                apps: [ManagedApp] = [], hosts: [HostPattern] = [],
                action: Action = .route) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.apps = apps
        self.hosts = hosts
        self.action = action
    }

    /// A rule with neither apps nor hosts cannot match anything meaningful;
    /// the UI flags these and the provider skips them.
    public var isValid: Bool { !apps.isEmpty || !hosts.isEmpty }
}

// MARK: - ShuntSettings with v1 → v2 migration

public struct ShuntSettings: Codable, Hashable {
    /// 1 = legacy (managedApps only). 2 = rules-aware.
    public var schemaVersion: Int
    /// Kept as the source of truth for the Apps tab and for the currently-running
    /// extension binary that predates `rules`. The new Rules UI (3d.6) will keep
    /// `managedApps` and `rules` in sync on every edit until the v1 extension
    /// binary is retired.
    public var managedApps: [ManagedApp]
    public var upstream: UpstreamProxy
    /// v2 compound rules. On v1 decode, auto-populated with one rule per
    /// managed app (`apps=[app], hosts=[], action=.route`).
    public var rules: [Rule]
    /// Active theme id. Defaults to "signal-amber". Opaque string here — the
    /// Shunt app module owns the actual Color values. Kept in settings (not
    /// UserDefaults) so export/import preserves user choice.
    public var themeID: String

    public init(managedApps: [ManagedApp] = [],
                upstream: UpstreamProxy = UpstreamProxy(),
                rules: [Rule]? = nil,
                themeID: String = "filament") {
        self.schemaVersion = 2
        self.managedApps = managedApps
        self.upstream = upstream
        self.rules = rules ?? Self.derive(apps: managedApps)
        self.themeID = themeID
    }

    public static let empty = ShuntSettings()

    /// Bundle IDs the v1 extension should claim, restricted to enabled entries
    /// with a non-empty bundle ID (empty is the "draft row" state from the UI).
    public var enabledBundleIDs: Set<String> {
        Set(managedApps.filter { $0.enabled && !$0.bundleID.isEmpty }.map(\.bundleID))
    }

    // MARK: Codable (with v1 → v2 migration)

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, managedApps, upstream, rules, themeID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.managedApps = (try? c.decode([ManagedApp].self, forKey: .managedApps)) ?? []
        self.upstream = (try? c.decode(UpstreamProxy.self, forKey: .upstream)) ?? UpstreamProxy()
        self.themeID = (try? c.decode(String.self, forKey: .themeID)) ?? "filament"
        let decodedSchemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        if c.contains(.rules) {
            self.rules = (try? c.decode([Rule].self, forKey: .rules)) ?? []
            self.schemaVersion = decodedSchemaVersion
        } else {
            // v1 input → migrate. One rule per managed app.
            self.rules = Self.derive(apps: self.managedApps)
            self.schemaVersion = 2
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(managedApps, forKey: .managedApps)
        try c.encode(upstream, forKey: .upstream)
        try c.encode(rules, forKey: .rules)
        try c.encode(themeID, forKey: .themeID)
    }

    /// Deterministic v1 → v2 mapping: one rule per managed app, preserving the
    /// enabled flag and using the display name as the rule name. Only used
    /// during the v1 → v2 initial migration.
    public static func deriveRules(from apps: [ManagedApp]) -> [Rule] {
        derive(apps: apps)
    }

    /// From 3d.6 onward `rules` is the ground truth and `managedApps` is a
    /// derivation kept around for the v1 extension binary (which doesn't know
    /// about rules). The union of enabled rules' apps, de-duplicated by bundle
    /// ID, is what the v1 extension will claim.
    public static func deriveManagedApps(from rules: [Rule]) -> [ManagedApp] {
        var seen: Set<String> = []
        var result: [ManagedApp] = []
        for rule in rules where rule.enabled {
            for app in rule.apps where !app.bundleID.isEmpty && !seen.contains(app.bundleID) {
                seen.insert(app.bundleID)
                result.append(app)
            }
        }
        return result
    }

    private static func derive(apps: [ManagedApp]) -> [Rule] {
        apps.map { app in
            Rule(
                name: app.displayName.isEmpty ? app.bundleID : app.displayName,
                enabled: app.enabled,
                apps: [app],
                hosts: [],
                action: .route
            )
        }
    }
}
