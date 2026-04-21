# Phase 3b Research — Consolidated findings (2026-04-21)

**Updated 2026-04-21** with second-round research that overturns the earlier transparent-proxy-entitlement assumption.

Seven parallel research agents investigated across two rounds: (1) canonical NE flow + samples, (2) NEAppRule semantics + DR matching, (3) NECP scoping + outbound connections, (4) startProxy diagnostic procedure, (5) Apple portal capability configuration, (6) open-source Developer-ID NETransparentProxyProvider apps, (7) Apple technotes on NE deployment. Evidence labels: **[CONFIRMED]** from Apple docs / DTS / WWDC; **[INFERRED]** from community + forum consensus; **[SPECULATIVE]** requires validation.

---

## 🎯 KEY FINDING (second-round research)

**`transparent-proxy-systemextension` DOES NOT EXIST as an entitlement value.** This is the cleanest, most actionable finding of the project. All three follow-up research agents (portal, open-source, technotes) converged on this independently:

- [CONFIRMED] Apple's public entitlement reference at <https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_developer_networking_networkextension> enumerates all possible values. The complete list is: `dns-proxy`, `app-proxy-provider`, `content-filter-provider`, `packet-tunnel-provider`, `dns-proxy-systemextension`, `app-proxy-provider-systemextension`, `content-filter-provider-systemextension`, `packet-tunnel-provider-systemextension`, `dns-settings`, `app-push-provider`, `relay`, `url-filter-provider`. The string `transparent-proxy-systemextension` is **absent**.
- [CONFIRMED from 3 open-source production apps] (madeye/BaoLianDeng, PIA mac-split-tunnel, mitmproxy/mitmproxy_rs): all use `NETransparentProxyProvider` with entitlement `app-proxy-provider-systemextension` and Info.plist NEProviderClasses key `com.apple.networkextension.app-proxy`. They do NOT use `.transparent-proxy` as the Info.plist key.
- [CONFIRMED] TN3134 "Network Extension provider deployment": transparent proxy packaged as system extension on macOS 10.15+ supports Developer ID distribution (no "App Store only" restriction in the transparent-proxy system-extension row).

**Why we got confused.** `NETransparentProxyProvider` is a subclass of `NEAppProxyProvider`. Both share the same entitlement (`app-proxy-provider-systemextension` for Developer ID) and the same Info.plist NEProviderClasses key (`com.apple.networkextension.app-proxy`). The class name "Transparent" is misleading — it refers to runtime behavior (flow diversion without `NEAppRule`), not to a distinct entitlement/extension-point. Our earlier `RESEARCH.md` §4.4 and the AI's internal knowledge both contained the phantom `transparent-proxy-systemextension` value, which was never real.

**Implication.** Our existing provisioning profile already contains everything we need. No Apple request needed. No capability configuration step missed. The earlier fix (switching entitlement to `app-proxy-provider-systemextension`) was correct on its own, but we paired it with the wrong Info.plist key (`.transparent-proxy`) instead of `.app-proxy`, which is why sysextd rejected the extension as "invalid extension point".

**Correct combination for Shunt:**

| Component | Value |
|---|---|
| Swift provider class | `NETransparentProxyProvider` |
| Entitlement value | `app-proxy-provider-systemextension` ← already in our profile |
| Info.plist NEProviderClasses key | `com.apple.networkextension.app-proxy` ← NOT `.transparent-proxy` |
| Main app manager class | `NETransparentProxyManager` |

---

## Original first-round summary (preserved below, sections 1-10)

---

## TL;DR — what to change before next iteration

1. **Pivot back to `NETransparentProxyProvider`** (not NEAppProxyProvider). **[CONFIRMED]** Quinn (Apple DTS, threads 131815 and 727985) explicitly recommends transparent proxy over app proxy for Developer-ID macOS because NEAppRule has documented breakage on Developer-ID target apps.
2. **Stop using `NEAppRule` entirely.** Use broad `includedNetworkRules` (0.0.0.0/0 TCP+UDP, ::/0) and filter by `flow.metaData.sourceAppSigningIdentifier` *inside* `handleNewFlow`. Return `true` to claim, `false` to pass through (macOS 11+ semantics). **[CONFIRMED]** Matt Eaton, thread 658631.
3. **Use POSIX sockets with `IP_BOUND_IF` to reach the Parallels VM.** NECP (Network Extension Control Protocol) scopes NWConnection to the primary NIC from inside an NE provider — this is designed, documented, and unfixable at the NWConnection layer. BSD sockets with explicit interface binding are the **Apple-blessed** bypass. **[CONFIRMED]** Quinn, threads 725715 + 736083 + 76711.
4. **Get the `transparent-proxy-systemextension` entitlement into the profile.** Must resolve BEFORE this pivot — we previously observed the Developer-ID profile's NE allowed-array did NOT contain it. Need to re-verify post-reboot: refresh profiles in the portal (enabling any sub-option we may have missed), or investigate if Apple silently added this to Developer-ID profiles in a later macOS release.
5. **Bring a `--deactivate` flag to the main app** before iterating. Zombie sysexts from rapid rebuilds block new provider resolution.

---

## 1. The critical misunderstandings from previous iterations

### 1.1 NEAppProxyProvider was the wrong base class

Previous session pivoted to `NEAppProxyProvider` because `transparent-proxy-systemextension` wasn't in our Developer-ID profile. **Agent 2 and Agent 4 both confirm this was wrong.** Quinn in thread 131815: *"most developers use a content filter provider or a transparent proxy provider rather than app proxy providers"* — specifically for Developer-ID. Thread 738636 (Apple SE confirmation): NEAppRule has historical breakage on Developer-ID target apps where flows get blocked instead of diverted.

**Resolution needed.** Why wasn't `transparent-proxy-systemextension` in the profile? Hypothesis: the "Network Extensions" capability on the App ID has a "Configure" sub-dialog we didn't expand. Or the profile predates newer macOS additions. Re-check the capability configuration post-reboot.

### 1.2 We spent a long time fighting NEAppRule

Both opposite errors (matchDomains required for Safari / forbidden for own-team ShuntTest) **[CONFIRMED]** from Apple's private validator `signingIdentifierAllowed:domainsRequired:` (Agent 2, private headers): same-team apps forbid matchDomains; third-party apps require them. This dichotomy isn't publicly documented but is the kernel behavior.

**Don't fight it. NETransparentProxyProvider doesn't use NEAppRule at all** — apps are filtered at `handleNewFlow` time via `sourceAppSigningIdentifier`. This sidesteps the entire validator.

### 1.3 Mach-O UUID tracking is likely why our test didn't work

**[CONFIRMED]** (Agent 4, thread 730032, Apple SE): `nesessionmanager` tracks rule-targeted apps by **Mach-O UUID**, not just bundle ID + DR. Every `swift build` produces a new UUID. So even if the DR matches and the rule saves, flows from the *new* build are invisible until we re-save the config to re-cache the UUID.

Safari worked because Safari's Mach-O UUID doesn't change between our runs. ShuntTest's UUID changes on every rebuild — each new build is a "different app" to NE.

**Another reason to abandon NEAppRule and filter in handleNewFlow** — no UUID tracking, just runtime bundle ID comparison.

---

## 2. Canonical NETransparentProxyProvider pattern (target architecture)

### 2.1 Container app setup (main app side)

```swift
NETransparentProxyManager.loadAllFromPreferences { managers, error in
    let manager = managers?.first ?? NETransparentProxyManager()
    let proto = NETunnelProviderProtocol()
    proto.providerBundleIdentifier = "com.craraque.shunt.proxy"
    proto.serverAddress = "Shunt"  // label only, not dialed
    manager.protocolConfiguration = proto
    manager.localizedDescription = "Shunt"
    manager.isEnabled = true
    // NOTE: appRules is NOT SET (would reject validation for transparent proxy)
    manager.saveToPreferences { err in
        manager.loadFromPreferences { err2 in  // mandatory re-load after save
            try? manager.connection.startVPNTunnel()
        }
    }
}
```

**[CONFIRMED]** (Agent 1, Quinn thread 130063): missing the `loadFromPreferences` re-load after save → silent `configurationStale` on tunnel start.

### 2.2 Provider side (system extension)

```swift
override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
    let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    // Broad catch-all — we filter by app in handleNewFlow
    let tcpRule = NENetworkRule(
        remoteNetwork: NWHostEndpoint(hostname: "0.0.0.0", port: "0"),
        remotePrefix: 0,
        localNetwork: nil, localPrefix: 0,
        protocol: .TCP, direction: .outbound
    )
    let udpRule = NENetworkRule(
        remoteNetwork: NWHostEndpoint(hostname: "0.0.0.0", port: "0"),
        remotePrefix: 0,
        localNetwork: nil, localPrefix: 0,
        protocol: .UDP, direction: .outbound
    )
    settings.includedNetworkRules = [tcpRule, udpRule]
    settings.excludedNetworkRules = []
    setTunnelNetworkSettings(settings) { [weak self] error in
        // CRITICAL: call completionHandler from INSIDE setTunnelNetworkSettings callback
        completionHandler(error)
    }
}

override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
    let app = flow.metaData.sourceAppSigningIdentifier
    guard claimedBundles.contains(app) else {
        return false  // macOS 11+: passes through untouched to default network path
    }
    guard let tcp = flow as? NEAppProxyTCPFlow else {
        return false  // Phase 3b defers UDP
    }
    // strong-retain bridge in provider dict; see architecture
    let bridge = SOCKS5Bridge(flow: tcp, ...)
    bridges[ObjectIdentifier(bridge)] = bridge
    bridge.onFinish = { [weak self] in self?.bridges.removeValue(forKey: ObjectIdentifier(bridge)) }
    bridge.start()
    return true
}
```

**Key rules (all [CONFIRMED]):**
- `completionHandler(error)` inside `setTunnelNetworkSettings` callback, not before (Quinn, thread 712295).
- Return `false` for unclaimed flows → pass-through (Matt Eaton, thread 658631).
- `handleNewFlow` is called for every flow matching `includedNetworkRules`; filtering is our job.

### 2.3 Info.plist for the extension

```xml
<key>NetworkExtension</key>
<dict>
    <key>NEMachServiceName</key>
    <string>group.com.craraque.shunt.proxy</string>
    <key>NEProviderClasses</key>
    <dict>
        <key>com.apple.networkextension.transparent-proxy</key>
        <string>ShuntProxy.ShuntProxyProvider</string>
    </dict>
</dict>
```

Entitlement must include `transparent-proxy-systemextension` in the `com.apple.developer.networking.networkextension` array — need to verify the profile now grants it.

---

## 3. NECP scoping — why outbound to Parallels fails, and the fix

### 3.1 The mechanism [CONFIRMED]

**Quinn, thread 725715 ("A Peek Behind the NECP Curtain"):**
> "NECP stands for Network Extension Control Protocol. When starting an NE provider, the system configures the NECP policy for the NE provider's process to prevent it from using a VPN interface."

**Quinn, thread 734293 ("Network Interface Concepts"):**
> "Apple uses scoped routing, where the route is chosen from both source address and destination. There is no global default-route fallback."

For our provider:
- NECP policy for the provider process steers outbound to the primary service-order interface (en0/en9 / WiFi).
- Parallels `bridge100` is not in that policy → connections to `10.211.55.5` get bound to en9 → SYN packets go out WiFi → never reach bridge100.
- The `scoped, ipv4, dns` token in NWConnection logs is the smoking gun of NECP scoping.

This is **designed behavior, not a bug, and cannot be disabled via public API at the NECP level.**

### 3.2 The Apple-sanctioned fix: BSD sockets with `IP_BOUND_IF`

**Quinn, thread 725715:**
> "An NE packet tunnel provider can use any networking API it wants, including BSD Sockets, to run its connection without fear of creating a VPN loop."

**Quinn, thread 736083 (working Swift code):**
```swift
let interface = if_nametoindex("bridge100")
try sock.setSocketOption(IPPROTO_IP, IP_BOUND_IF, interface)
try sock.connect("10.211.55.5", 1080)
```

**Quinn, thread 76711:**
> "`IP_BOUND_IF` is the right option here. This works well for BSD Sockets and things tightly tied to it (like CFSocket and GCD). It does not work at all for higher-level APIs, like NSURLSession."

Why BSD bypasses scoping: `NWConnection` routes via Network.framework's path-selection which consults NECP before choosing the local address. BSD `socket()` + `setsockopt(IPPROTO_IP, IP_BOUND_IF, ...)` sets the scope on the socket directly via `inp_boundifp` — the kernel's route lookup uses that scope as-is. NECP still sees the socket, but scoped bindings cannot be re-scoped.

### 3.3 Our existing `POSIXTCPClient.swift` must add IP_BOUND_IF

Current implementation (`Sources/ShuntProxy/POSIXTCPClient.swift`) doesn't bind to an interface. Add:

```swift
import Darwin

let ifIndex = if_nametoindex("bridge100")  // UInt32
var idx = UInt32(ifIndex)
let rv = setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size))
// check rv == 0
```

Before `connect()`. Must be called on an IPv4 socket (AF_INET). For IPv6, use `IPV6_BOUND_IF`.

### 3.4 Alternative considered and rejected

- `NWParameters.requiredInterface = bridge100-NWInterface` — Agent 3 gave this 70% odds of working. **[SPECULATIVE]** whether NECP overrides requiredInterface in NE-provider context. If we're committing to a fix, IP_BOUND_IF is the certainty. Skip NWParameters path.
- `SO_BINDTOINTERFACE` is **Linux-only**, does not exist on Darwin.
- Loopback relay (run a user-agent helper bound to bridge100, relay via 127.0.0.1) — works but adds a component. Not needed when BSD+IP_BOUND_IF is one-line.
- `pfctl rdr` from 127.0.0.1 → 10.211.55.5 — hacky, moves the problem. Don't.

---

## 4. Why startProxy wasn't being invoked (post-mortem of the stuck state)

From Agent 4, ranked likely causes for "tunnel connected but startProxy silent":

1. **[MOST LIKELY]** Mach-O UUID drift on `com.craraque.shunt.test`. Fixes with architectural pivot (transparent proxy + handleNewFlow filtering).
2. **[LIKELY]** DR string-mismatch. Codesign extracts DR with certificate marker OIDs + whitespace. Hand-written DRs almost never match byte-for-byte. Extract at runtime via `SecStaticCodeCreateWithPath` + `SecCodeCopyDesignatedRequirement` + `SecRequirementCopyString`. **Moot once we pivot** (no DR in transparent proxy).
3. **[POSSIBLE]** Zombie providers. 8+ versions in `[terminated waiting to uninstall on reboot]`. Reboot clears them.
4. **[POSSIBLE]** `providerBundleIdentifier` mismatch with installed extension's `CFBundleIdentifier`. Verify with `defaults read /Library/Preferences/com.apple.networkextension.plist | plutil -convert xml1 -o - -`.
5. **[POSSIBLE]** `NEProviderClasses` key wrong for class type (app-proxy vs transparent-proxy). Must match the base class we pick.

---

## 5. Diagnostic playbook for next iteration

### 5.1 Enable verbose NE logging (one-time)

```bash
# Install Apple's NE diagnostic profile (unmasks <private> tokens in logs):
open https://developer.apple.com/bug-reporting/profiles-and-logs/
# Download "Network Extension" profile, install from System Settings → Privacy → Profiles

# Increase daemon log level:
sudo defaults write /Library/Preferences/com.apple.networkextension.control.plist LogLevel -int 6
sudo defaults write /Library/Preferences/com.apple.networkextension.control.plist LogToFile -int 1
# Reboot for changes to take effect
```

After this, NE logs land at `/Library/Logs/com.apple.networkextension.*.log` and the live-stream predicate below reveals rule decisions, flow routing, and provider lifecycle.

### 5.2 Canonical log stream predicate

```bash
log stream --level debug --style compact --predicate \
  '(subsystem == "com.apple.networkextension") OR
   (process == "neagent") OR
   (process == "nesessionmanager") OR
   (process == "sysextd") OR
   (subsystem == "com.craraque.shunt") OR
   (subsystem == "com.craraque.shunt.proxy")'
```

### 5.3 Keyphrases to grep

- `"Plugin type ... registered"` — sysext came up successfully
- `"Starting plugin"` / `"started plugin instance"` — startProxy is about to fire
- `"app rule ... matched"` — which binary matched which rule (only relevant if we keep NEAppRule, which we won't)
- `"validation failed"` / `"designated requirement not satisfied"` — smoking gun for DR mismatch
- `"no matching"` / `"dropped"` / `"unable to find"` — flow rejected before provider

### 5.4 First-light test

Add in the provider's `init()` (not just startProxy):

```swift
override init() {
    super.init()
    let log = Logger(subsystem: "com.craraque.shunt.proxy", category: "provider")
    log.info("FIRST LIGHT — ShuntProxyProvider instantiated")
}
```

If you don't see FIRST LIGHT when a tunnel starts, the extension is never being spawned — issue is pre-provider (bundle ID / plist / zombies).

### 5.5 Clean slate every iteration

```bash
# After reboot:
systemextensionsctl list   # confirm no zombies
scutil --nc list            # confirm no stale Shunt configs

# Remove stale configs programmatically if present:
# (build the --remove-config flag first; see §7)
```

---

## 6. Canonical outbound pattern (putting it together)

Provider's bridge pseudocode:

```swift
override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
    guard claimedBundles.contains(flow.metaData.sourceAppSigningIdentifier) else { return false }
    guard let tcp = flow as? NEAppProxyTCPFlow else { return false }
    let bridge = SOCKS5Bridge(flow: tcp, socksHost: "10.211.55.5", socksPort: 1080, iface: "bridge100", logger: logger)
    retain(bridge)
    bridge.start()
    return true
}

// SOCKS5Bridge.start():
func start() {
    flow.open(withLocalEndpoint: nil) { error in
        if let error = error { self.abort(error); return }
        self.openBSD()
    }
}

func openBSD() {
    fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    var ifIdx = if_nametoindex("bridge100")
    setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &ifIdx, socklen_t(MemoryLayout<UInt32>.size))
    var addr = sockaddr_in(...)  // 10.211.55.5:1080
    connect(fd, ...)  // should succeed now — bound to bridge100
    self.socks5Handshake()
}

// Pump bytes between flow and fd via DispatchSource / GCD read/write
```

---

## 7. Dev workflow improvements (must-do before next iteration)

Per `tasks/todo.md` Phase 3b improvements section:

- **`--deactivate` flag** on main app → `OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier:)`. Submits uninstall; extension transitions to `[terminated waiting to uninstall on reboot]`. Use at end of each test cycle.
- **`--remove-config` flag** → `NEAppProxyProviderManager.loadAllFromPreferences` → each `.removeFromPreferences()`. Clears VPN config cleanly.
- **Replace `CFBundleVersion = $(date +%s)` in build.sh** with semver before shipping. Timestamp is fine during dev but dirty for prod.
- **First-light Logger in provider init()** — see §5.4.
- **Enable Apple NE diagnostic profile** before iterating — see §5.1. Makes log output usable.

---

## 8. The architectural pivot — concrete changes

### Files to modify (UPDATED per second-round research)

1. **`Sources/ShuntProxy/ShuntProxyProvider.swift`**
   - Base class: `NETransparentProxyProvider` (subclass of NEAppProxyProvider — shares entitlement).
   - `startProxy`: configure `NETransparentProxyNetworkSettings` with a catch-all `includedNetworkRules` (outbound TCP + UDP). Call `completionHandler(error)` from INSIDE the `setTunnelNetworkSettings` callback.
   - `handleNewFlow`: filter by `flow.metaData.sourceAppSigningIdentifier`; return `false` for non-claimed flows (pass-through, macOS 11+ semantics).

2. **`Resources/ShuntProxy-Info.plist`**
   - `NEProviderClasses` key: **`com.apple.networkextension.app-proxy`** (NOT `.transparent-proxy` — that was our prior bug). Value: `ShuntProxy.ShuntProxyProvider`.
   - Keep `NEMachServiceName` as `group.com.craraque.shunt.proxy` (prefixed by our App Group).

3. **`Resources/ShuntProxy.entitlements` and `Shunt.entitlements`**
   - `com.apple.developer.networking.networkextension` value: **`[app-proxy-provider-systemextension]`** (we already had this right in the App Proxy pivot; keep).
   - **No profile change needed** — our existing profiles already allow this value.

4. **`Sources/Shunt/Core/ProxyManager.swift`**
   - Switch from `NEAppProxyProviderManager` to `NETransparentProxyManager`.
   - **REMOVE** all `appRules` logic — NETransparentProxyProvider doesn't use NEAppRule.
   - Keep `loadAllFromPreferences → save → loadFromPreferences → startVPNTunnel` pattern.

5. **`Sources/ShuntProxy/POSIXTCPClient.swift`**
   - Add `setsockopt(IPPROTO_IP, IP_BOUND_IF, if_nametoindex("bridge100"))` before `connect()`.
   - Hardcode `bridge100` for Phase 3b; Phase 3c can make configurable.

6. **`Sources/Shunt/App/AppDelegate.swift`**
   - Add `--deactivate` flag handler → `OSSystemExtensionRequest.deactivationRequest`.
   - Add `--remove-config` flag handler → loadAll managers, removeFromPreferences each.

### Reference implementations

Three production Developer-ID-signed apps that ship this exact pattern:

- **madeye/BaoLianDeng** — <https://github.com/madeye/BaoLianDeng>. `TransparentProxyProvider: NETransparentProxyProvider`, entitlement `app-proxy-provider-systemextension`, Info.plist key `com.apple.networkextension.app-proxy`. Catch-all `includedNetworkRules`, filters in `handleNewFlow` by `sourceAppSigningIdentifier`. `scripts/build-release-pkg.sh` is a good reference for PKG + notarize pipeline.
- **pia-foss/mac-split-tunnel** — <https://github.com/pia-foss/mac-split-tunnel>. Same pattern. Their CI uses a sed-replace to swap `app-proxy-provider` → `app-proxy-provider-systemextension` between dev and release builds (they keep the MAS-suffixed version in git for `systemextensionsctl developer on` local dev).
- **mitmproxy/mitmproxy_rs** (macos-redirector) — <https://github.com/mitmproxy/mitmproxy_rs>. Cleanest minimal example. `TransparentProxyProvider: NETransparentProxyProvider`, async/await overrides. Good `ExportOptions.plist` reference for `developer-id` method with manual provisioning profiles.

---

## 9. Open questions carried forward (ALL RESOLVED in second-round research — see key finding at top of doc)

1. ~~**Why wasn't `transparent-proxy-systemextension` in our profile?**~~ **Resolved.** That entitlement string doesn't exist. Our profile is complete — we just need to use `app-proxy-provider-systemextension` with the `.app-proxy` Info.plist key.
2. ~~**Is there an Apple TN on NE system extension lifecycle?**~~ **Resolved.** TN3134 "Network Extension provider deployment" is that document. It confirms transparent proxy system extension supports Developer ID distribution (no "App Store only" restriction).
3. **Does `includedNetworkRules` with `0.0.0.0/0` actually work as the catch-all?** Partially resolved — BaoLianDeng and mitmproxy both use a single catch-all outbound rule. Implementation detail to verify at code time: exact form of `NENetworkRule(remoteNetwork:…, remotePrefix:0, protocol:.TCP, direction:.outbound)`.

---

## 10. Source URLs (all consulted this session)

### Apple Developer Forums (Quinn / Matt Eaton / Apple SE)
- <https://developer.apple.com/forums/thread/725715> — NECP explained
- <https://developer.apple.com/forums/thread/734293> — Network Interface Concepts
- <https://developer.apple.com/forums/thread/734359> — Network Interface Techniques
- <https://developer.apple.com/forums/thread/736083> — IP_BOUND_IF working code
- <https://developer.apple.com/forums/thread/76711> — BSD vs high-level APIs
- <https://developer.apple.com/forums/thread/131815> — Developer ID AppProxy recommendations
- <https://developer.apple.com/forums/thread/130063> — Full container-app recipe
- <https://developer.apple.com/forums/thread/74194> — How to start NEAppProxyProvider
- <https://developer.apple.com/forums/thread/712295> — startProxy completion handler
- <https://developer.apple.com/forums/thread/727985> — Transparent proxy flow-filter pattern
- <https://developer.apple.com/forums/thread/717140> — startProxy options
- <https://developer.apple.com/forums/thread/713057> — NWConnection outbound pattern
- <https://developer.apple.com/forums/thread/738636> — NEAppRule Developer-ID breakage
- <https://developer.apple.com/forums/thread/658631> — Return false = pass through (macOS 11+)
- <https://developer.apple.com/forums/thread/704467> — Provider sandbox
- <https://developer.apple.com/forums/thread/730032> — Mach-O UUID tracking
- <https://developer.apple.com/forums/thread/652143> — DR must match; matchPath doesn't
- <https://developer.apple.com/forums/thread/129250> — Zombie sysexts
- <https://developer.apple.com/forums/thread/725805> — Debugging NE providers
- <https://developer.apple.com/forums/thread/69924> — NE lifecycle logging
- <https://developer.apple.com/forums/thread/657352> — Deactivating NE
- <https://developer.apple.com/forums/thread/688853> — handleNewFlow not called
- <https://developer.apple.com/forums/thread/694391> — Flow source identification
- <https://developer.apple.com/forums/thread/744044> — IP_BOUND_IF + includeAllNetworks

### Apple documentation
- <https://developer.apple.com/documentation/networkextension/neappproxyprovider>
- <https://developer.apple.com/documentation/networkextension/app-proxy-provider>
- <https://developer.apple.com/documentation/networkextension/neapprule/matchdomains>
- <https://developer.apple.com/documentation/networkextension/neapprule/matchdesignatedrequirement>
- <https://developer.apple.com/documentation/networkextension/netransparentproxyprovider>
- <https://developer.apple.com/documentation/network/nwparameters/requiredinterface>
- <https://developer.apple.com/documentation/security/seccodecopydesignatedrequirement(_:_:_:)>
- <https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment>
- <https://developer.apple.com/documentation/technotes/tn3178-checking-for-and-resolving-build-uuid-problems>

### WWDC
- <https://asciiwwdc.com/2019/sessions/714> — WWDC 2019 Session 714 transcript

### Other
- <https://developer.apple.com/bug-reporting/profiles-and-logs/> — NE diagnostic profile
- <https://blog.timac.org/2018/0717-macos-vpn-architecture/> — macOS VPN architecture
- <https://blog.kandji.io/mac-logging-and-the-log-command-a-guide-for-apple-admins>
