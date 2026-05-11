import Foundation

public struct SystemExtensionVersion: Equatable, Sendable {
    public let shortVersion: String
    public let build: String

    public init(shortVersion: String, build: String) {
        self.shortVersion = shortVersion
        self.build = build
    }

    public var numericBuild: Int? { Int(build) }

    public var displayString: String {
        "\(shortVersion)/\(build)"
    }

    public static func parseActiveVersion(
        fromSystemExtensionsOutput output: String,
        bundleIdentifier: String
    ) -> SystemExtensionVersion? {
        SystemExtensionSnapshot.parse(
            fromSystemExtensionsOutput: output,
            bundleIdentifier: bundleIdentifier
        )?.version
    }
}

public enum SystemExtensionActivationState: Equatable, Sendable {
    case activatedEnabled
    case activatedWaitingForUser
    case terminatedWaitingToUninstallOnReboot
    case other(String)

    public var displayString: String {
        switch self {
        case .activatedEnabled:
            return "activated enabled"
        case .activatedWaitingForUser:
            return "waiting for user approval"
        case .terminatedWaitingToUninstallOnReboot:
            return "restart required"
        case .other(let raw):
            return raw
        }
    }

    fileprivate var priority: Int {
        switch self {
        case .activatedEnabled: return 0
        case .activatedWaitingForUser: return 1
        case .other: return 2
        case .terminatedWaitingToUninstallOnReboot: return 3
        }
    }

    static func parse(from line: Substring) -> SystemExtensionActivationState {
        if line.contains("[activated enabled]") { return .activatedEnabled }
        if line.contains("[activated waiting for user]") { return .activatedWaitingForUser }
        if line.contains("[terminated waiting to uninstall on reboot]") { return .terminatedWaitingToUninstallOnReboot }
        if let open = line.lastIndex(of: "["),
           let close = line[line.index(after: open)...].firstIndex(of: "]") {
            return .other(String(line[line.index(after: open)..<close]))
        }
        return .other("unknown")
    }
}

public struct SystemExtensionSnapshot: Equatable, Sendable {
    public let version: SystemExtensionVersion
    public let state: SystemExtensionActivationState

    public init(version: SystemExtensionVersion, state: SystemExtensionActivationState) {
        self.version = version
        self.state = state
    }

    public var displayString: String {
        "\(version.displayString) · \(state.displayString)"
    }

    public static func parse(
        fromSystemExtensionsOutput output: String,
        bundleIdentifier: String
    ) -> SystemExtensionSnapshot? {
        var matches: [SystemExtensionSnapshot] = []
        for line in output.split(separator: "\n") {
            guard line.contains(bundleIdentifier) else { continue }
            guard let open = line.lastIndex(of: "("),
                  let close = line[line.index(after: open)...].firstIndex(of: ")")
            else { continue }
            let versionBuild = String(line[line.index(after: open)..<close])
            let parts = versionBuild.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            matches.append(SystemExtensionSnapshot(
                version: SystemExtensionVersion(shortVersion: parts[0], build: parts[1]),
                state: SystemExtensionActivationState.parse(from: line)
            ))
        }
        return matches.sorted { lhs, rhs in
            if lhs.state.priority != rhs.state.priority { return lhs.state.priority < rhs.state.priority }
            return (lhs.version.numericBuild ?? 0) > (rhs.version.numericBuild ?? 0)
        }.first
    }
}

public enum SystemExtensionCompatibilityStatus: Equatable, Sendable {
    case compatible
    case updateAvailable
    case updateRequired
    case awaitingUserApproval
    case restartRequired
    case notInstalled
    case bundledMissing
    case unknown

    public var title: String {
        switch self {
        case .compatible:
            return "System Extension is current"
        case .updateAvailable:
            return "System Extension update available"
        case .updateRequired:
            return "System Extension update required"
        case .awaitingUserApproval:
            return "System Extension awaiting approval"
        case .restartRequired:
            return "Restart required to finish extension update"
        case .notInstalled:
            return "System Extension not installed"
        case .bundledMissing:
            return "Bundled System Extension not found"
        case .unknown:
            return "System Extension status unknown"
        }
    }

    public var requiresUserAction: Bool {
        switch self {
        case .updateAvailable, .updateRequired, .awaitingUserApproval, .restartRequired, .notInstalled, .bundledMissing, .unknown:
            return true
        case .compatible:
            return false
        }
    }
}

public enum SystemExtensionCompatibility {
    public static func evaluate(
        active: SystemExtensionSnapshot?,
        bundled: SystemExtensionVersion?,
        minimumRequiredBuild: Int?
    ) -> SystemExtensionCompatibilityStatus {
        guard let bundled else { return .bundledMissing }
        guard let active else { return .notInstalled }

        switch active.state {
        case .activatedWaitingForUser:
            return .awaitingUserApproval
        case .terminatedWaitingToUninstallOnReboot:
            return .restartRequired
        case .activatedEnabled, .other:
            break
        }

        if let minimumRequiredBuild,
           let activeBuild = active.version.numericBuild,
           activeBuild < minimumRequiredBuild {
            return .updateRequired
        }

        if let activeBuild = active.version.numericBuild,
           let bundledBuild = bundled.numericBuild,
           activeBuild < bundledBuild {
            return .updateAvailable
        }

        if active.version.shortVersion != bundled.shortVersion {
            return .updateAvailable
        }

        return .compatible
    }

    public static func evaluate(
        active: SystemExtensionVersion?,
        bundled: SystemExtensionVersion?,
        minimumRequiredBuild: Int?
    ) -> SystemExtensionCompatibilityStatus {
        evaluate(
            active: active.map { SystemExtensionSnapshot(version: $0, state: .activatedEnabled) },
            bundled: bundled,
            minimumRequiredBuild: minimumRequiredBuild
        )
    }
}
