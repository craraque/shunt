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

public struct ShuntSettings: Codable, Hashable {
    public var managedApps: [ManagedApp]
    public var upstream: UpstreamProxy

    public init(managedApps: [ManagedApp] = [], upstream: UpstreamProxy = UpstreamProxy()) {
        self.managedApps = managedApps
        self.upstream = upstream
    }

    public static let empty = ShuntSettings()

    /// Bundle IDs the extension should claim, restricted to enabled entries.
    public var enabledBundleIDs: Set<String> {
        Set(managedApps.filter(\.enabled).map(\.bundleID))
    }
}
