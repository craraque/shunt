import Foundation
import Darwin

/// Matches a flow's destination against a `HostPattern`.
///
/// Hostname is typically the pre-resolved name from `NEAppProxyTCPFlow.remoteHostname`
/// (what the app dialed — e.g. "github.com"). The IP is the already-resolved literal
/// from `remoteEndpoint.hostname`. Some patterns only work with one or the other.
public enum HostMatcher {

    public static func matches(_ pattern: HostPattern, hostname: String?, ip: String?) -> Bool {
        switch pattern.kind {
        case .exact:
            guard let host = hostname, !host.isEmpty else { return false }
            return host.lowercased() == pattern.pattern.lowercased()

        case .suffix:
            guard let host = hostname?.lowercased(), !host.isEmpty else { return false }
            let needle = pattern.pattern.lowercased()
            let suffix = needle.hasPrefix("*.") ? String(needle.dropFirst(2)) : needle
            guard !suffix.isEmpty else { return false }
            return host == suffix || host.hasSuffix("." + suffix)

        case .cidr:
            guard let ipStr = ip, !ipStr.isEmpty else { return false }
            return cidrMatches(pattern.pattern, ip: ipStr)
        }
    }

    /// Evaluate whether a rule matches a flow, per compound AND semantics.
    /// `apps == []` means "any app"; `hosts == []` means "any host".
    public static func ruleMatches(_ rule: Rule, bundleID: String, hostname: String?, ip: String?) -> Bool {
        if !rule.apps.isEmpty {
            let bundleIDs = Set(rule.apps.map(\.bundleID))
            guard bundleIDs.contains(bundleID) else { return false }
        }
        if !rule.hosts.isEmpty {
            guard rule.hosts.contains(where: { matches($0, hostname: hostname, ip: ip) }) else { return false }
        }
        return true
    }

    // MARK: - CIDR matching (IPv4 + IPv6)

    private static func cidrMatches(_ cidr: String, ip: String) -> Bool {
        let parts = cidr.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let prefixLen = Int(parts[1]) else { return false }
        let network = parts[0]

        if let ipBytes = v4Bytes(ip), let netBytes = v4Bytes(network), prefixLen >= 0, prefixLen <= 32 {
            return prefixMatches(ipBytes, netBytes, bits: prefixLen)
        }
        if let ipBytes = v6Bytes(ip), let netBytes = v6Bytes(network), prefixLen >= 0, prefixLen <= 128 {
            return prefixMatches(ipBytes, netBytes, bits: prefixLen)
        }
        return false
    }

    private static func v4Bytes(_ s: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    private static func v6Bytes(_ s: String) -> [UInt8]? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, s, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    private static func prefixMatches(_ a: [UInt8], _ b: [UInt8], bits: Int) -> Bool {
        guard a.count == b.count else { return false }
        guard bits >= 0, bits <= a.count * 8 else { return false }
        let fullBytes = bits / 8
        let remBits = bits % 8
        for i in 0..<fullBytes where a[i] != b[i] { return false }
        if remBits > 0 {
            let mask = UInt8(0xFF) << (8 - remBits)
            if (a[fullBytes] & mask) != (b[fullBytes] & mask) { return false }
        }
        return true
    }
}

// MARK: - Test helper: detect if IP parses

public extension HostMatcher {
    /// Returns `true` if the given string parses as an IPv4 or IPv6 literal.
    /// Used by the provider to decide whether `remoteEndpoint.hostname` should
    /// feed the `ip` argument of `matches(...)`.
    static func isIPLiteral(_ s: String) -> Bool {
        v4Bytes(s) != nil || v6Bytes(s) != nil
    }
}
