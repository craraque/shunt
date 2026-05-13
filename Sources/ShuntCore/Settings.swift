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

    /// SOCKS5 username/password auth. When BOTH are non-empty, the bridge
    /// negotiates `05 02 00 02` greeting + RFC 1929 user/pass subnegotiation
    /// instead of the no-auth `05 01 00` path. Default empty = no-auth.
    public var username: String
    public var password: String

    /// Phase 7 — when true, SOCKS5 CONNECT requests use ATYP=0x03 (domain
    /// name) for FQDN destinations, deferring DNS resolution to the upstream
    /// proxy. Improves hostname-based filtering at the upstream (for URL
    /// policy or SNI matching) and avoids DNS leaks of routed hostnames to the
    /// host's local resolvers.
    ///
    /// Falls back automatically to ATYP=0x01 / 0x04 when the destination is
    /// already an IP literal, so apps that connect directly by IP keep
    /// working. Default `true` for new entries; legacy decode lands on
    /// `false` to preserve the exact behaviour shipped before this field
    /// existed (no surprise migration).
    public var useRemoteDNS: Bool

    public init(host: String = "127.0.0.1",
                port: UInt16 = 1080,
                bindInterface: String? = nil,
                username: String = "",
                password: String = "",
                useRemoteDNS: Bool = true) {
        self.host = host
        self.port = port
        self.bindInterface = bindInterface
        self.username = username
        self.password = password
        self.useRemoteDNS = useRemoteDNS
    }

    /// True iff both username + password are non-empty after trimming.
    public var requiresAuth: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // Custom Codable so adding `username` / `password` / `useRemoteDNS` as
    // new fields doesn't reset existing settings files. Older payloads
    // decode fine with the new fields defaulting to safe values.
    private enum CodingKeys: String, CodingKey {
        case host, port, bindInterface, username, password, useRemoteDNS
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.host = (try? c.decode(String.self, forKey: .host)) ?? "127.0.0.1"
        self.port = (try? c.decode(UInt16.self, forKey: .port)) ?? 1080
        self.bindInterface = try? c.decodeIfPresent(String.self, forKey: .bindInterface)
        self.username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? ""
        self.password = (try? c.decodeIfPresent(String.self, forKey: .password)) ?? ""
        // Legacy decode → `true` because the pre-toggle behaviour was
        // already "prefer the hostname when the OS gives us one" (provider
        // passes `tcp.remoteHostname` to SOCKS5Bridge, which already sends
        // ATYP=0x03 for non-IP-literal targets). Defaulting to `true` here
        // preserves that exact behaviour. Toggle OFF forces IP-literal
        // CONNECT (ATYP=0x01/0x04) using the OS's resolved endpoint.
        self.useRemoteDNS = (try? c.decodeIfPresent(Bool.self, forKey: .useRemoteDNS)) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encodeIfPresent(bindInterface, forKey: .bindInterface)
        // Only write username/password when set, to keep the JSON minimal
        // and to keep secrets out of the file when not used.
        if !username.isEmpty { try c.encode(username, forKey: .username) }
        if !password.isEmpty { try c.encode(password, forKey: .password) }
        try c.encode(useRemoteDNS, forKey: .useRemoteDNS)
    }
}

// MARK: - Upstream launcher (Phase 3f)

/// A command Shunt runs before enabling the tunnel and stops after disabling it.
/// Entries are grouped into stages; stages run sequentially, entries within a
/// stage run in parallel. See `docs/upstream-launcher.md`.
/// What Shunt should do when the launcher detects this entry is *already
/// healthy* on enable (i.e. the underlying daemon was started outside Shunt's
/// supervision). Determines whether the entry is treated as `ownedByUs` and
/// therefore whether `stopCommand` runs on disable.
public enum LauncherExternalPolicy: String, Codable, CaseIterable, Hashable {
    /// Default for new entries. Engine emits a `pendingDecision` event so the
    /// UI can prompt the user. Until they answer, the entry behaves as
    /// `neverReclaim` (no stopCommand on disable).
    case ask
    /// Treat already-running instances as ours. `stopCommand` always runs on
    /// disable. Use for VMs / daemons whose lifecycle Shunt fully manages
    /// (Parallels, Tart with no other consumers).
    case alwaysReclaim
    /// Legacy behavior — only run stopCommand for processes Shunt itself
    /// spawned in this session. Use when something else may have started the
    /// daemon and stopping it would inconvenience another consumer.
    case neverReclaim
}

public struct UpstreamLauncherEntry: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    /// Shell command run via `/bin/zsh -l -c` so the user's PATH resolves
    /// `tart`, `brew`-installed binaries, etc. Ignored when the health probe
    /// already passes at startup (idempotency).
    public var startCommand: String
    /// Optional explicit stop command. When nil, the engine SIGTERMs the PID
    /// it tracked at spawn time (with a 10 s grace then SIGKILL). When set,
    /// the string is run via the same shell as `startCommand`.
    public var stopCommand: String?
    public var healthProbe: HealthProbe
    public var probeIntervalSeconds: Int
    public var startTimeoutSeconds: Int
    /// How to treat instances already running on enable. See enum docs.
    public var externalPolicy: LauncherExternalPolicy

    public init(id: UUID = UUID(),
                name: String = "",
                enabled: Bool = true,
                startCommand: String = "",
                stopCommand: String? = nil,
                healthProbe: HealthProbe = .portOpen,
                probeIntervalSeconds: Int = 2,
                startTimeoutSeconds: Int = 60,
                externalPolicy: LauncherExternalPolicy = .ask) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.startCommand = startCommand
        self.stopCommand = stopCommand
        self.healthProbe = healthProbe
        self.probeIntervalSeconds = probeIntervalSeconds
        self.startTimeoutSeconds = startTimeoutSeconds
        self.externalPolicy = externalPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, startCommand, stopCommand
        case healthProbe, probeIntervalSeconds, startTimeoutSeconds
        case externalPolicy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.startCommand = try c.decode(String.self, forKey: .startCommand)
        self.stopCommand = try c.decodeIfPresent(String.self, forKey: .stopCommand)
        self.healthProbe = try c.decode(HealthProbe.self, forKey: .healthProbe)
        self.probeIntervalSeconds = try c.decode(Int.self, forKey: .probeIntervalSeconds)
        self.startTimeoutSeconds = try c.decode(Int.self, forKey: .startTimeoutSeconds)
        // Backward-compat: pre-policy entries get .neverReclaim so existing
        // workflows (Tart spawned externally, etc.) keep their legacy
        // "Shunt doesn't touch what it didn't start" guarantee. New entries
        // created via UI default to .ask.
        self.externalPolicy = (try? c.decodeIfPresent(LauncherExternalPolicy.self, forKey: .externalPolicy)) ?? .neverReclaim
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(startCommand, forKey: .startCommand)
        try c.encodeIfPresent(stopCommand, forKey: .stopCommand)
        try c.encode(healthProbe, forKey: .healthProbe)
        try c.encode(probeIntervalSeconds, forKey: .probeIntervalSeconds)
        try c.encode(startTimeoutSeconds, forKey: .startTimeoutSeconds)
        try c.encode(externalPolicy, forKey: .externalPolicy)
    }
}

/// A group of entries that run in parallel. Stages themselves run sequentially
/// in the order they appear in `UpstreamLauncher.stages`.
public struct UpstreamLauncherStage: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var entries: [UpstreamLauncherEntry]

    public init(id: UUID = UUID(), name: String = "Stage", entries: [UpstreamLauncherEntry] = []) {
        self.id = id
        self.name = name
        self.entries = entries
    }
}

public struct UpstreamLauncher: Codable, Hashable {
    public var stages: [UpstreamLauncherStage]

    public init(stages: [UpstreamLauncherStage] = []) {
        self.stages = stages
    }

    public static let empty = UpstreamLauncher()

    /// Convenience: every entry across every stage, flattened in declared order.
    public var allEntries: [UpstreamLauncherEntry] {
        stages.flatMap(\.entries)
    }
}

/// How the engine decides an entry is "ready". The first two modes only look
/// at the upstream socket; the last two validate the end-to-end egress path
/// (ZCC auth gate, geo-shift proxy, etc.).
public enum HealthProbe: Codable, Hashable {
    /// TCP connect to `upstream.host:upstream.port`. Fast, no false negatives
    /// on the happy path, but false-positive during the "daemon up, ZCC auth
    /// pending" window.
    case portOpen
    /// TCP connect + SOCKS5 greeting exchange (`05 01 00` → `05 00`). Proves a
    /// SOCKS5 server is answering; still doesn't validate upstream egress.
    case socks5Handshake
    /// TCP connect to an explicit host/port. Use for prerequisite readiness
    /// that is not the final upstream socket (for example VM SSH on :22).
    case tcpConnect(host: String, port: UInt16)
    /// SOCKS5 greeting against an explicit host/port. Use when a launcher stage
    /// exposes a local tunnel before the global upstream is fully switched.
    case socks5HandshakeAt(host: String, port: UInt16)
    /// Run a shell command and pass only when it exits 0. Useful for VM-ready
    /// checks such as `prlctl exec "VM" /usr/bin/true`.
    case commandExitZero(command: String)
    /// Fetch `probeURL` through the upstream SOCKS5 proxy, parse the body as
    /// an IP string, and match against `cidr`. Use when the expected egress
    /// range is known.
    case egressCidrMatch(cidr: String, probeURL: URL)
    /// Fetch `probeURL` twice — once direct, once through the upstream SOCKS5 —
    /// and pass only when the two IPs differ. CIDR-free, works for any
    /// upstream whose purpose is to shift egress off the local ISP.
    case egressDiffersFromDirect(probeURL: URL)

    /// Default probe URL when the user picks an egress-based mode for the
    /// first time. `https://ifconfig.me/ip` returns a plain IP body, no JSON.
    public static let defaultProbeURL = URL(string: "https://ifconfig.me/ip")!
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
    /// Prerequisite processes Shunt starts before the tunnel and stops after.
    /// Empty (the default) is a no-op — existing settings files without this
    /// field decode fine and behave as they did pre-Phase-3f.
    public var launcher: UpstreamLauncher

    public init(managedApps: [ManagedApp] = [],
                upstream: UpstreamProxy = UpstreamProxy(),
                rules: [Rule]? = nil,
                themeID: String = "filament",
                launcher: UpstreamLauncher = .empty) {
        self.schemaVersion = 2
        self.managedApps = managedApps
        self.upstream = upstream
        self.rules = rules ?? Self.derive(apps: managedApps)
        self.themeID = themeID
        self.launcher = launcher
    }

    public static let empty = ShuntSettings()

    /// Bundle IDs the v1 extension should claim, restricted to enabled entries
    /// with a non-empty bundle ID (empty is the "draft row" state from the UI).
    public var enabledBundleIDs: Set<String> {
        Set(managedApps.filter { $0.enabled && !$0.bundleID.isEmpty }.map(\.bundleID))
    }

    // MARK: Codable (with v1 → v2 migration)

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, managedApps, upstream, rules, themeID, launcher
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.managedApps = (try? c.decode([ManagedApp].self, forKey: .managedApps)) ?? []
        self.upstream = (try? c.decode(UpstreamProxy.self, forKey: .upstream)) ?? UpstreamProxy()
        self.themeID = (try? c.decode(String.self, forKey: .themeID)) ?? "filament"
        self.launcher = (try? c.decode(UpstreamLauncher.self, forKey: .launcher)) ?? .empty
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
        try c.encode(launcher, forKey: .launcher)
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
