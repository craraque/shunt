# Shunt — Technical Research

**Status:** Research / specification. Do NOT treat as implementation guide yet — open questions in Section 7 must be resolved first.

**Audience:** Cesar (senior Swift/Mac developer, Apple Silicon M2 Max, personal BYOD Mac, no MDM) and a future Claude Code session that will implement this.

**Problem statement:** Run Microsoft Teams, Outlook, and a user-configurable list of corporate apps *natively on macOS* while their traffic is transparently routed through a Zscaler Client Connector running inside a local VM. All other host traffic continues to use the host's direct internet connection. This is the legitimate BYOD inverse of the usual case: the Mac is personal, Zscaler stays fully functional for corporate apps, but is *isolated from the host OS* instead of interposed on it.

**Non-goals:**
- Evading, hiding from, or disabling Zscaler for corporate traffic.
- Whole-system tunneling.
- Supporting Intel Macs or macOS < 14.

---

## Section 1 — macOS per-app traffic interception

### 1.1 `NETransparentProxyProvider` (NetworkExtension, packaged as System Extension)

**What it is.** A subclass of `NEAppProxyProvider` introduced in **macOS 11 (Big Sur)**, purpose-built for transparent per-flow interception on the Mac. Unlike iOS-style per-app VPNs, a Transparent Proxy System Extension sees flows from **all apps on the system** (not just MDM-installed ones), and your provider decides per-flow whether to claim the flow (and forward it elsewhere) or let it pass through unmodified to the default system path.

**Core API surface.**

- Main app side: `NETransparentProxyManager` — creates/saves/loads the configuration in the system's NetworkExtension preferences (same plumbing that `NEVPNManager` uses).
- Extension side: subclass `NETransparentProxyProvider` (itself a `NEAppProxyProvider` subclass).
  - `startProxy(options:completionHandler:)` — called when the manager is enabled. Call `setTunnelNetworkSettings` on `self` with an `NETransparentProxyNetworkSettings` whose `includedNetworkRules` / `excludedNetworkRules` are `[NENetworkRule]`.
  - `handleNewFlow(_ flow: NEAppProxyFlow) -> Bool` — return `true` to *claim* the flow (you own it now and must pump its bytes), `false` to *pass through* to the system. The flow is either an `NEAppProxyTCPFlow` or an `NEAppProxyUDPFlow`. Read `flow.metaData` for `sourceAppAuditToken`, `sourceAppSigningIdentifier`, `sourceAppUniqueIdentifier`.
  - `handleNewUDPFlow(_:initialRemoteEndpoint:)` — macOS 11.3+ explicit UDP entrypoint.
  - `stopProxy(with:completionHandler:)` — tear down.

**Flow forwarding to a remote SOCKS/HTTP proxy (the VM).** The provider does *not* get raw packets; it gets a pair of `read`/`write` async methods on the flow. The idiomatic pattern for forwarding to a SOCKS5 proxy on the VM:

1. On `handleNewFlow`, inspect `flow.metaData.sourceAppSigningIdentifier` (a String — e.g. `com.microsoft.teams2`, `com.microsoft.Outlook`) and compare against Shunt's configured bundle list.
2. If matched: `flow.open(withLocalEndpoint: nil) { ... }` (TCP) or just start reading for UDP, open a `NWConnection` to the VM's SOCKS5 endpoint (`192.168.x.y:1080` if bridged, or `127.0.0.1:1080` if port-forwarded), negotiate SOCKS5 with the flow's `remoteEndpoint` as the target, then start two "copier" tasks (`flow.readData` → `socket.send`, `socket.receive` → `flow.write`). Return `true` to claim the flow.
3. If not matched: return `false`. The OS sends the flow through its normal path (direct internet, no Zscaler). This is the whole point — passthrough is first-class.

Reference: the loop pattern is documented in the Apple forums thread "How to multiplex possibly thousands of flows" and the `SimpleTunnel` samples. Flow reads/writes are non-blocking completion-handler style; Swift concurrency (`withCheckedContinuation`) wraps them cleanly. Sources: [NETransparentProxyProvider](https://developer.apple.com/documentation/NetworkExtension/NETransparentProxyProvider), [NEAppProxyFlow](https://developer.apple.com/documentation/networkextension/neappproxyflow), [WWDC19 714](https://developer.apple.com/videos/play/wwdc2019/714/).

**`NENetworkRule` match keys.** Rules are coarse — they match on protocol family, remote host/port/prefix, and direction. They do **not** filter by originating app. App-level filtering must happen inside `handleNewFlow` by inspecting `sourceAppSigningIdentifier` / `sourceAppAuditToken`. For Shunt that's fine because we want to *see every TCP/UDP flow* and only claim those from our managed bundle IDs.

Typical include rule to see everything:

```swift
let tcpAll = NENetworkRule(
    remoteNetwork: nil,
    remotePrefix: 0,
    localNetwork: nil,
    localPrefix: 0,
    protocol: .TCP,
    direction: .outbound
)
let udpAll = NENetworkRule(
    remoteNetwork: nil,
    remotePrefix: 0,
    localNetwork: nil,
    localPrefix: 0,
    protocol: .UDP,
    direction: .outbound
)
settings.includedNetworkRules = [tcpAll, udpAll]
// excludedNetworkRules: exclude local/link-local so mDNS, Bonjour, AirDrop, etc. stay native.
```

**What it can/cannot intercept.**

| Protocol | Supported? | Notes |
|---|---|---|
| TCP (IPv4/IPv6) | Yes | `NEAppProxyTCPFlow`. Solid since macOS 11. |
| UDP (IPv4/IPv6) | Yes, with caveats | `NEAppProxyUDPFlow`. Historically buggy on beta builds (Big Sur/Monterey regressions). Stable on macOS 14+. |
| QUIC / HTTP/3 | Yes (as UDP) | QUIC is UDP on port 443. The provider sees the UDP flows; it has no QUIC-layer awareness. Forwarding over SOCKS5 UDP ASSOCIATE works but many SOCKS proxies drop UDP — see Section 6. |
| ICMP | **No** | Not surfaced as a flow. Ping won't go through. |
| Raw sockets | **No** | Transparent proxy never sees them. |
| Multicast / broadcast | No | Not in flow abstraction. |
| VPN-like system flows | Filtered by OS | The extension is told not to see its own traffic. |

Sources: [Transparent proxy UDP flows](https://developer.apple.com/forums/thread/690456), [QUIC forum thread](https://developer.apple.com/forums/thread/724369).

**Source app identification.** Three keys on `flow.metaData`:
- `sourceAppSigningIdentifier: String` — the bundle signing identifier. For most Mac apps this equals the bundle ID (e.g. `com.microsoft.teams2`). This is what Shunt should match on.
- `sourceAppUniqueIdentifier: Data` — a stable team-scoped identifier; useful if two apps share a bundle ID.
- `sourceAppAuditToken: Data` — raw audit token. Use `audit_token_to_pid()` etc. from `libbsm` if a `pid` is needed.

These are available because the flow originates from a system app (not an MDM-installed app); they are **not** gated behind any `NEAppRule`/MDM configuration on macOS Transparent Proxy Provider (this is one of the Mac-specific advantages over iOS Per-App VPN). Source: [WWDC19 714 transcript](https://asciiwwdc.com/2019/sessions/714).

**Requirements and lifecycle.**

| Aspect | Requirement |
|---|---|
| Paid Apple Dev account | **Yes** ($99/yr). Free accounts (Personal Team) cannot use NE. |
| Entitlements | `com.apple.developer.networking.networkextension` → array containing `"transparent-proxy-systemextension"`; `com.apple.developer.system-extension.install` on the container app. |
| User approval | **Yes** — user must approve in System Settings → General → Login Items & Extensions → Network Extensions the first time. |
| VPN profile consent | **Yes** — saving the `NETransparentProxyManager` triggers a system dialog ("Shunt would like to add VPN Configurations"). |
| Apple Silicon | **Yes**, native. |
| Reboot persistence | Yes. Approved and configured extensions re-load automatically. |
| Sleep/wake | Yes. The extension is re-activated on wake; flows in progress during sleep are torn down normally. |
| TLS 1.3 handling | Transparent — provider sees the encrypted bytes; no MITM involved. |
| API maturity | macOS 11+ (2020), stabilized on macOS 13+; recommended API for new Mac network-proxy work by Apple. |

Sources: [Network Extensions Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension), [Configuring network extensions](https://developer.apple.com/documentation/xcode/configuring-network-extensions), [Login Items & Extensions UX](https://support.apple.com/en-us/120363).

### 1.2 `NEAppProxyProvider` (classic per-app VPN)

Super-class of Transparent Proxy Provider. On macOS it requires the flows to be routed to it via an `NEAppRule` list bound to specific bundle IDs/signing IDs. Historically this was the "iOS per-app VPN" mechanism: an MDM pushes an NEAppRule, and matching apps get their flows handed to the provider. On the Mac, `NEAppRule` works without MDM, but the configuration path is clunkier than Transparent Proxy.

**Differences vs Transparent Proxy:**

| Dimension | `NEAppProxyProvider` | `NETransparentProxyProvider` |
|---|---|---|
| Scope | Apps bound via `NEAppRule` | All apps (filter in `handleNewFlow`) |
| MDM needed | No on macOS, yes on iOS | No |
| Matching | Driven by `NEAppRule.matchSigningIdentifier` | Freeform in code |
| UDP | Yes | Yes |
| Passthrough concept | "Doesn't see" non-matched flows | "Returns false" to pass through |
| Apple's Mac recommendation | Legacy / iOS-centric | **Recommended** |

For Shunt, Transparent Proxy is strictly more flexible: we can re-order the configured bundle list dynamically in UserDefaults without rebuilding the `NEAppRule` list, and we see everything so we can log "flow from app X not matched — bypassed" for debugging.

Source: [NEAppProxyProvider](https://developer.apple.com/documentation/networkextension/neappproxyprovider), [NEAppRule.matchSigningIdentifier](https://developer.apple.com/documentation/networkextension/neapprule/matchsigningidentifier).

### 1.3 `NEFilterPacketProvider` / `NEFilterDataProvider` (content filter)

**Non-option.** A content filter can *allow* or *deny* flows; it cannot *redirect* them. You cannot "forward this flow to a SOCKS proxy on a VM" from inside a filter. Mentioned here only to rule it out.

### 1.4 `NEPacketTunnelProvider`

Whole-system packet tunnel. Useful if we wanted every byte the Mac emits to go via Zscaler (which is the default Zscaler Mac client behavior and the exact opposite of what we want). Dismissed.

### 1.5 `pfctl` with per-UID rules (hacky alternative)

Idea: create a dedicated macOS user `zuser`, run Teams/Outlook as that user via `launchctl asuser` or a wrapper script, and add a pf anchor that `rdr`'s TCP/UDP from `user zuser` to `127.0.0.1:1080` (a SOCKS tunnel endpoint to the VM).

**Real-world problems:**

- **DNS** happens under `_mdnsresponder`, not the calling UID, so per-UID rules don't match DNS traffic. You'd need to run a local DNS resolver inside the proxy path as well.
- **pf `rdr` rules don't support user/group match on translation rules** on macOS — only filter rules match on user. Source: [macOS PF manual](https://murusfirewall.com/Documentation/OS%20X%20PF%20Manual.pdf).
- Teams/Outlook running as a different UID can't talk to the logged-in user's Keychain, notifications, Login Keychain items, SSO tokens, AppleScript, etc. Teams in particular *assumes* the logged-in GUI user.
- App-level sandboxing breaks in subtle ways (temp dirs, MDM policies, document access).
- Requires root to load the pf ruleset; no entitlements but lots of fragility.

**Pros:** Zero Apple entitlements. Would work for CLI tools (`curl`, `git`, etc.) behind a per-UID proxy.

**Verdict:** Not suitable for Shunt. Too fragile for GUI apps. Note it only as a "last-resort CLI trick".

### 1.6 PAC file + SOCKS/HTTP proxy on VM

Idea: run a SOCKS5/HTTP proxy inside the VM forwarded to the host. Ship a PAC file served from `http://127.0.0.1:<localport>/shunt.pac` that says "for hosts matching corporate patterns, go via proxy; else direct". Point the host at the PAC via `networksetup -setautoproxyurl Wi-Fi http://127.0.0.1:<port>/shunt.pac` + `-setautoproxystate Wi-Fi on`.

**Reality check:**

- **Teams does not reliably honor the system proxy** — reports across Microsoft Q&A and Tech Community are consistently negative. Teams uses its own networking stack with its own proxy logic (and often ignores system proxy on macOS). Sources: [MS Teams isn't respecting Proxy Settings](https://learn.microsoft.com/en-us/answers/questions/467351/ms-teams-isnt-respecting-proxy-settings), [Teams desktop client proxy settings](https://techcommunity.microsoft.com/t5/office-365/microsoft-teams-desktop-client-proxy-settings/td-p/1473194).
- **Outlook on macOS (new WebView2/Monarch builds)** has dropped direct proxy config and uses system settings poorly. Older Outlook honored system proxy for EWS; the new one is less consistent.
- **QUIC ignores HTTP proxies entirely.** Teams media (audio/video) is UDP/QUIC and will not traverse a SOCKS5 proxy unless the proxy supports UDP ASSOCIATE *and* Teams's media stack cooperates (it doesn't).
- **Proxy scope is global per network service.** The PAC file can limit *which destinations* are proxied but not *which apps* originate the traffic — a browser on your host visiting a corp URL would also go through Zscaler, which may or may not be desired.

**Pros:** Zero entitlements. Works today. Fine fallback for strictly-HTTP corporate web apps.

**Verdict:** Useful as Option B fallback for HTTP-only corporate web apps, but cannot be the primary mechanism for Teams/Outlook.

### 1.7 Hybrid approach

A robust real-world deployment likely mixes:

1. `NETransparentProxyProvider` — primary, per-app match on `sourceAppSigningIdentifier`.
2. DNS policy inside the extension — override DNS for corporate domains to resolve via the VM, so the VM's Zscaler sees the intended destination (this matters if Zscaler uses DNS-based steering).
3. Local PAC fallback for users who haven't approved the system extension yet (Shunt can run in "degraded mode" for web-only apps).

### 1.8 Pros/cons table

| Mechanism | Per-app? | UDP/QUIC? | Entitlement? | User approval? | Effort | Fit for Teams/Outlook |
|---|---|---|---|---|---|---|
| `NETransparentProxyProvider` | Yes (in-code filter by bundle ID) | Yes | Yes (managed) | Yes (System Settings + VPN consent) | High | Excellent |
| `NEAppProxyProvider` | Yes (via `NEAppRule`) | Yes | Yes (managed) | Yes | High | Good, but clunkier |
| `NEFilterPacketProvider` | Filter only | — | Yes | Yes | — | Not applicable |
| `NEPacketTunnelProvider` | No (whole system) | Yes | Yes | Yes | High | Wrong shape |
| `pfctl` per-UID | Weak (per-UID) | Partial | None | Admin only | Medium | Poor for GUI apps |
| PAC + SOCKS | Destination-based, not app-based | No (HTTP only) | None | None | Low | Poor for Teams media |

### 1.9 Recommendation

**Use `NETransparentProxyProvider`, packaged as a System Extension, forwarding claimed flows over SOCKS5 (with UDP ASSOCIATE support) to the VM.**

Rationale:
1. Designed by Apple for exactly this shape: per-flow decision, unmodified passthrough for unmatched flows.
2. Native per-app identification via `sourceAppSigningIdentifier` with no MDM.
3. Handles TCP and UDP (incl. QUIC as UDP) — the only native API that can plausibly cover Teams media.
4. Stable since macOS 13, clean Swift concurrency ergonomics on macOS 14+.
5. Entitlement is gettable on a Developer ID profile (see Section 4).

Keep PAC + SOCKS as a documented "degraded fallback" for users who refuse to approve the system extension, and as a zero-privilege PoC harness (Section 6).

---

## Section 2 — Hypervisor comparison

All candidates assumed on Apple Silicon (M2 Max, 128 GB). "Headless" here means "no VM window in the Dock/Spaces while running."

### 2.1 Parallels Desktop

- **arm64 native:** Yes.
- **Guest OS:** Windows 11 ARM (officially licensed via Microsoft — Parallels is the **only** Microsoft-authorized virtualization path for Windows 11 on Apple Silicon), macOS, Linux.
- **Idle overhead:** ~400–800 MB RAM, low CPU.
- **Networking:** Shared (NAT) with optional port forwarding via `/Library/Preferences/Parallels/network.desktop.xml`; Bridged (picks a host NIC); Host-only. Port forwarding from guest to host works; from host to guest over Shared uses Parallels's built-in forwarder.
- **CLI:** `prlctl list -a`, `prlctl start "VM"`, `prlctl stop`, `prlctl exec`, `prlsrvctl net set`. Parallels also has a Terraform provider and Vagrant plugin, so scripting surface is mature. Source: [Parallels CLI docs](https://docs.parallels.com/parallels-desktop-developers-guide/command-line-interface-utility/manage-virtual-machines-from-cli/general-virtual-machine-management/power-operations).
- **Headless start:** Available in **Pro edition only** via "startup view" = headless option, or `prlctl start ... --no-window` style flags. Source: [KB Parallels headless mode](https://kb.parallels.com/en/123298).
- **Cost:** Subscription, ~$100/yr Standard, more for Pro/Business. Pro is required for headless + some networking features.

### 2.2 VMware Fusion

- **arm64 native:** Yes (Fusion 13+).
- **Guest OS:** Windows 11 ARM (works but **not** Microsoft-authorized), macOS (Apple Silicon), Linux.
- **Idle overhead:** Similar to Parallels, sometimes slightly higher.
- **Networking:** NAT, Bridged, Host-only, Private. NAT port forwarding is configurable in `/Library/Preferences/VMware Fusion/vmnet8/nat.conf`.
- **CLI:** `vmrun` at `/Applications/VMware Fusion.app/Contents/Library/vmrun` — `start <vmx> nogui`, `stop`, `suspend`, `runProgramInGuest`. Source: [vmruncli](https://github.com/alexdotsh/vmruncli).
- **Headless start:** Yes, `nogui` flag is the supported path.
- **Cost:** **Free** for personal, educational, and commercial use since November 2024. Source: [Macworld comparison](https://www.macworld.com/article/668848/best-virtual-machine-software-for-mac.html).

### 2.3 UTM (QEMU + Apple Virtualization Framework frontend)

- **arm64 native:** Yes (uses AVF) or full emulation via QEMU (slow).
- **Guest OS:** Windows 11 ARM (unlicensed path, Microsoft has not authorized; works in practice via Dev Channel ARM ISO), macOS, Linux (arm64).
- **Idle overhead:** Low when using AVF backend.
- **Networking:** Shared (NAT, default), Bridged, Host-only, Emulated VLAN. **Port forwarding is only available on the QEMU backend with Emulated VLAN**, not on the AVF backend — this is a real limitation. Source: [UTM port forwarding docs](https://docs.getutm.app/settings-qemu/devices/network/port-forwarding/).
- **CLI:** Limited. `utmctl` exists (`utmctl list`, `utmctl start`, `utmctl stop`), but scripting surface is thinner than Parallels/Fusion.
- **Headless start:** Yes via `utmctl start <uuid> --disable-display` (macOS only).
- **Cost:** **Free** (open source); $9.99 on the App Store as a convenience.

### 2.4 Apple Virtualization Framework directly (VirtualBuddy / Viable / Tart / custom)

- **arm64 native:** Yes — this *is* the native path.
- **Guest OS:** **macOS and Linux only.** Cannot run Windows (no x86/ARM-Windows path — AVF rejects the Windows boot flow).
- **Idle overhead:** Lowest of all options (it's the same path the OS itself uses).
- **Networking modes:** NAT (default), Bridged (requires `com.apple.vm.networking` entitlement — restricted to virtualization-app developers; Apple grants only on request), File-handle (lets you hand the VM an fd and implement networking yourself). Source: [VZBridgedNetworkInterface](https://developer.apple.com/documentation/virtualization/vzbridgednetworkinterface).
- **Known Sequoia issue:** Some users have reported `RTF_REJECT` routes being installed on `bridge100` for AVF VMs, breaking host→guest traffic in bridged mode. Source: [UTM discussion #7472](https://github.com/utmapp/UTM/discussions/7472). NAT mode is not affected.
- **CLI:** Depends on tool. **Tart** (`brew install cirruslabs/cli/tart`) is the best CLI story — `tart run <name>`, OCI-registry based image distribution, designed for CI. [Tart](https://tart.run/).
- **VirtualBuddy:** Open-source GUI, macOS guests only, ships with VirtualBuddyGuest for clipboard/shared-folder. Good for human-driven PoC, weaker CLI. [VirtualBuddy](https://github.com/insidegui/VirtualBuddy).
- **Cost:** Free.

### 2.5 CrossOver / Wine — ruled out

CrossOver is Wine, i.e. a Windows-API reimplementation, not a VM. The Zscaler Windows client ships a kernel-mode driver (`zstunnel`/`zsatunnel` driver) for its network stack, and Wine does not emulate NT kernel drivers. Even if the installer were coaxed into running, the tunnel interface it expects to bind cannot be created. Corporate-grade endpoint agents are the single worst fit for Wine. **Dismiss.**

### 2.6 Comparison table

| Criterion | Parallels | VMware Fusion | UTM | AVF direct (Tart/VirtualBuddy) |
|---|---|---|---|---|
| arm64 native | Yes | Yes | Yes | Yes |
| Runs Windows 11 ARM | **Yes, licensed** | Yes, unlicensed | Yes, unlicensed | **No** |
| Runs macOS guest | Yes | Yes | Yes | Yes |
| Runs Linux guest | Yes | Yes | Yes | Yes |
| NAT + port forward | Yes | Yes | Only on QEMU backend | NAT yes; forward via `socat`/userspace |
| Bridged | Yes | Yes | Yes | Needs restricted entitlement |
| Headless start | Pro edition | Yes (`vmrun nogui`) | Yes (`utmctl --disable-display`) | Yes (native) |
| CLI for lifecycle | **Excellent** (`prlctl`) | Good (`vmrun`) | Basic (`utmctl`) | Tart: excellent; VB: weak |
| Idle RAM | ~500 MB | ~500–800 MB | ~400 MB | ~200–400 MB |
| Cost | ~$100/yr | **Free** | **Free** | **Free** |

### 2.7 Phased recommendation

- **PoC (now):** Use the **user's existing Windows VM** (whichever hypervisor hosts it). If it's Parallels, that's ideal — the CLI is the richest. If it's VMware Fusion or UTM, equally fine. Goal at PoC stage is proving the interception shape, not the VM shape.
- **Production, cost-minimizing (default recommendation):** **VMware Fusion** hosting a **Windows 11 ARM** guest. Free, solid networking, clean `vmrun` headless story, Zscaler Windows ARM is officially supported.
- **Production, best-of-both if budget allows:** **Parallels Desktop Pro** with a **Windows 11 ARM** guest, for Microsoft-licensed Windows, the richest CLI, and Coherence for occasional direct interaction with the guest if needed.
- **Long-term aspirational (lightest possible):** **Tart + AVF + macOS guest**, *only if* Zscaler licensing permits macOS-in-VM (see Section 3). This saves ~300–500 MB RAM and ~5–10% CPU vs Windows ARM.

---

## Section 3 — Guest OS + Zscaler client

### 3.1 Windows 11 ARM

- Zscaler Client Connector has native Windows ARM64 support since **ZCC 4.0** (2023). Zscaler publicly announced the Microsoft partnership for ARM. Source: [Zscaler Partners with Microsoft to Secure LTE ARM Devices](https://www.zscaler.com/blogs/product-insights/zscaler-partners-microsoft-secure-lte-arm-devices), [Works on WoA](https://www.worksonwoa.com/en/applications/zscalerclientconnector/).
- LTS versions for 2026 exist (Jan 31, 2026 start, 12 months). Source: [ZCC Long-Term Support](https://www.zscaler.com/blogs/product-insights/long-term-support-zscaler-client-connector).
- **Status: fully supported, the safe default.**

### 3.2 macOS guest (via AVF only)

- Technically: AVF can run a macOS guest on Apple Silicon (macOS 12+ as guest), and Zscaler Client Connector for macOS would install normally in that guest.
- **Licensing ambiguity.** Zscaler Client Connector is licensed per-device/per-user. Running the macOS client inside an AVF macOS guest on your personal Mac is **not explicitly addressed** in the public Zscaler documentation this research covered. Apple's own macOS EULA allows up to 2 additional VMs of macOS for development/testing on licensed Mac hardware — that part is fine. What's unclear is whether Zscaler's enrollment counts this as an additional device, whether the corporate IT team's deployment policy permits it, and whether the Zscaler tenant's posture/compliance checks (certificate, device ID, device posture via ZDX) will accept a VM identity. **This must be confirmed with the user's IT or Zscaler rep before committing.** Source: [Zscaler macOS user guide](https://help.zscaler.com/zpa/zscaler-client-connector/zscaler-client-connector-user-guide-macos).
- **Advantages if licensing is OK:** ~half the RAM vs Windows, native Apple Silicon kernel so ZCC's kexts/system extensions align with the host architecture, tooling (Tart) is excellent.
- **Risk:** Some enterprise MDM/ZDX postures detect virtualization and refuse enrollment.

### 3.3 Linux guest

- Zscaler Client Connector for Linux **exists** and is downloadable. Feature parity is historically incomplete: posture checks, some MDM-pushed policies, and UI features lag behind Windows/macOS. Source: [ZCC Linux install options](https://help.zscaler.com/zscaler-client-connector/customizing-zscaler-client-connector-install-options-linux), [ZCC Platform page](https://www.zscaler.com/products-and-solutions/zscaler-client-connector).
- arm64 Linux support for ZCC is unclear in public docs — the published packages are x86_64-centric. Flag as "check with Zscaler" if Linux-guest becomes a preferred path.
- **Verdict:** Not a great first choice unless corporate IT explicitly blesses Linux enrollment.

### 3.4 Recommendation

- **PoC:** Windows 11 ARM in the user's existing VM.
- **Production (default):** Windows 11 ARM. Best-supported, no licensing ambiguity.
- **Production (stretch):** macOS guest via AVF, *contingent on written permission from user's IT/Zscaler* (see Section 7 open questions).

---

## Section 4 — Apple entitlement approval strategy

### 4.1 Distribution path: Developer ID + notarization (NOT App Store)

System Extensions and the full NetworkExtension entitlement set are distributable **outside the Mac App Store** via Developer ID + notarization. This avoids App Store review (which is editorial and rejects things like "a utility that routes other apps' traffic somewhere the user controls"). Notarization is automated malware scanning — no human reviewer evaluates the utility's concept.

Key facts:

- The container app must be signed with a **Developer ID Application** certificate (not Mac App Distribution).
- System Extension bundle inside `Contents/Library/SystemExtensions/` must also be Developer ID-signed.
- Hardened Runtime (`codesign -o runtime`) is required for notarization.
- `xcrun notarytool submit ... --wait` + `xcrun stapler staple Shunt.app` for the distribution path. Source: [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

### 4.2 Required entitlements

On the **container (UI) app**:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.networking.networkextension</key>
    <array>
        <string>transparent-proxy-systemextension</string>
    </array>
    <key>com.apple.developer.system-extension.install</key>
    <true/>
</dict>
</plist>
```

On the **system extension bundle**:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.networking.networkextension</key>
    <array>
        <string>transparent-proxy-systemextension</string>
    </array>
</dict>
</plist>
```

Both bundles share a team ID and the same Network Extension entitlement value. The container also needs the install entitlement. Source: [Network Extensions Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension).

### 4.3 Requesting the entitlement from Apple

The Network Extension entitlement is **managed** — you cannot self-enable it in the Developer Portal. Request path:

1. Sign into [developer.apple.com/contact/network-extension](https://developer.apple.com/contact/network-extension). (If that URL is stale: [Apple Dev Support Contact](https://developer.apple.com/contact/) → Programs and Payments / Certificates, Identifiers and Profiles → "Request Network Extension Entitlement".)
2. Alternative email path: `networkextension@apple.com`.
3. Provide: Team ID, app bundle ID, extension bundle ID, which entitlement values you need (`transparent-proxy-systemextension`), a one-paragraph description of the use case.
4. Apple replies via email, typically in **1–4 weeks**. They may ask for clarification.

Sources: [Network Extension Framework Entitlement thread](https://developer.apple.com/forums/thread/67613), [contact page](https://developer.apple.com/contact/network-extension).

### 4.3b UPDATE (2026-04-20): entitlement is NOT managed

Verified against Apple's current process: `transparent-proxy-systemextension` is **not a managed capability** and does **not** require a request to Apple. Source: the new "Capability Requests" tab on each App ID in Certificates, Identifiers & Profiles lists only DriverKit Family Networking, Hotspot Helper, Manage Thread Network Credentials, Multicast Networking, and Web Browser Engine Networking as network-related managed capabilities. `Network Extensions` is a plain capability on the Capabilities tab — enable it on the App ID and the extension can claim the `*-systemextension` values directly.

The legacy URL `https://developer.apple.com/contact/network-extension` now redirects to `/contact/request/hotspot-helper/` because Hotspot Helper is one of the few NE providers that still requires Apple approval (per the Apple Developer Forums thread 67613, "most Network Extension provider capabilities no longer require Apple authorization" since November 2016).

**Net effect for Shunt:** no 1–4 week wait. Section 4.4 below is kept for historical reference but should NOT be executed.

### 4.4 Suggested wording for the request (HISTORICAL — not needed)

Short, specific, honest. Emphasize **per-app routing**, **user-controlled destination**, **segmentation** (not bypass). Avoid "VPN avoidance", "bypass", "hide", "evade".

> **Subject:** Network Extension Entitlement Request — Transparent Proxy System Extension (Team ID XXXXXXXXXX)
>
> We are requesting `transparent-proxy-systemextension` under `com.apple.developer.networking.networkextension` for bundle ID `com.craraque.shunt` (container) and `com.craraque.shunt.proxy` (system extension).
>
> Shunt is a macOS utility for bring-your-own-device (BYOD) professionals. It allows the user to designate a list of corporate applications (e.g. Microsoft Teams, Microsoft Outlook) whose outbound TCP/UDP flows are forwarded to a user-controlled, locally-running virtual machine that runs the user's corporate VPN client. All other flows are passed through to the system's default network path unchanged.
>
> The goal is **per-application network segmentation** on personal devices: keeping the user's personal traffic off the corporate VPN while still giving their corporate applications the network environment those applications require. This is the inverse of a whole-system VPN — we only claim flows the user has explicitly opted into, identified by `sourceAppSigningIdentifier`, and we never modify, inspect, or intercept the bytes of flows we pass through.
>
> Shunt will be distributed outside the Mac App Store, signed with our Developer ID Application certificate, notarized, and installed by the user with explicit System Extension approval in System Settings → Login Items & Extensions. No MDM is used. No flow content is read or logged by Shunt; the VM's corporate VPN client is the sole destination for claimed flows.
>
> Happy to provide a demo build or additional detail.
>
> Thanks,
> Cesar Araque

### 4.5 Common rejection reasons and timeline

- **"Use a lower-privilege API."** Mitigate by explaining why PAC/filter/NEVPN don't fit (see Section 1 of this doc).
- **"Your description sounds like a VPN bypass tool."** Mitigate by the framing above: *segmentation, per-app, user-controlled, inverse of whole-system VPN*.
- **"We don't see what the system extension does."** Be ready to send a pre-built binary or a short screen recording.
- **Silence.** Re-ping after 2 weeks politely with the same request.

Expected timeline: 1–4 weeks for first response; potentially a follow-up cycle. Plan 4–8 weeks from request to approved provisioning profile.

### 4.6 Code signing and notarization pipeline

End-to-end pipeline (to be scripted in a future `Scripts/release.sh`):

1. Build: `swift build -c release --arch arm64` for both the app and the system extension target.
2. Assemble `Shunt.app` with `Contents/Library/SystemExtensions/com.craraque.shunt.proxy.systemextension/` inside.
3. Sign **bottom-up**:
   ```
   codesign --force --options runtime --timestamp \
     --entitlements Extension.entitlements \
     --sign "Developer ID Application: Cesar Araque (TEAMID)" \
     Shunt.app/Contents/Library/SystemExtensions/com.craraque.shunt.proxy.systemextension
   codesign --force --options runtime --timestamp \
     --entitlements App.entitlements \
     --sign "Developer ID Application: Cesar Araque (TEAMID)" \
     Shunt.app
   ```
4. Zip: `ditto -c -k --keepParent Shunt.app Shunt.zip`.
5. Notarize: `xcrun notarytool submit Shunt.zip --apple-id ... --team-id ... --password ... --wait`.
6. Staple: `xcrun stapler staple Shunt.app`.
7. Distribute as `.zip` or `.dmg`. (If `.pkg`, add a Developer ID Installer cert.)

Sources: [Developer ID](https://developer.apple.com/developer-id/), [macOS distribution gist](https://gist.github.com/rsms/929c9c2fec231f0cf843a1a746a416f5).

### 4.7 In-app System Extension install UX

The container app drives activation via `OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier:queue:)` + an `OSSystemExtensionRequestDelegate`. First activation triggers:

1. macOS alert: "System Extension Blocked". User clicks "Open Security Settings".
2. User clicks "Allow" in System Settings → General → Login Items & Extensions → Network Extensions.
3. Shunt's delegate receives `.completed`.
4. Next: call `NETransparentProxyManager.saveToPreferences` which triggers the "Shunt would like to add VPN Configurations" system dialog (requires Touch ID / password).
5. Then `manager.connection.startVPNTunnel(options: nil)`.

UX should mirror what ZoomRooms/1Password/Little Snitch do: a one-time onboarding screen that explains each of the two prompts before firing them, with progress state (pending / approved / active).

Source: [If you get an alert about a system extension](https://support.apple.com/en-us/120363), [Sequoia Login Items & Extensions management](https://derflounder.wordpress.com/2024/09/16/blocking-system-extension-disablement-via-system-settings-on-macos-sequoia/).

---

## Section 5 — Recommended architecture

### 5.1 Option A (recommended) — Transparent Proxy System Extension → SOCKS5 inside VM

```
┌─────────────────────────────────────────────────────────────────────┐
│  macOS host (Apple Silicon, personal BYOD)                          │
│                                                                     │
│   Teams.app                           Safari.app                    │
│   Outlook.app                         <dev tools>                   │
│     │                                   │                           │
│     │ TCP/UDP flow                      │ TCP/UDP flow              │
│     ▼                                   ▼                           │
│  ┌──────────────────────────────────────────────────────┐           │
│  │  macOS kernel networking                             │           │
│  │  (all outbound flows offered to transparent proxy)   │           │
│  └──────────────────┬──────────────────┬────────────────┘           │
│                     │ claimed          │ passthrough                │
│                     ▼                  ▼                            │
│  ┌────────────────────────────┐   ┌────────────────────┐            │
│  │ Shunt SystemExtension   │   │ default route      │            │
│  │ (NETransparentProxy)       │   │ en0 / Wi-Fi        │            │
│  │ matches bundle IDs:        │   └─────────┬──────────┘            │
│  │   com.microsoft.teams2     │             │                       │
│  │   com.microsoft.Outlook    │             ▼                       │
│  │   <user-added>             │      direct internet                │
│  └──────────┬─────────────────┘                                     │
│             │ SOCKS5 (TCP + UDP ASSOCIATE)                          │
│             │ to 127.0.0.1:1080                                     │
│             ▼                                                       │
│  ┌──────────────────────────────────────────────────────┐           │
│  │  Hypervisor NAT port-forward 127.0.0.1:1080 →        │           │
│  │  guest 10.211.55.x:1080                              │           │
│  └──────────────────┬───────────────────────────────────┘           │
└─────────────────────┼───────────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Windows 11 ARM guest (VMware Fusion or Parallels)                  │
│                                                                     │
│  ┌─────────────────────────┐   ┌────────────────────────────┐       │
│  │ SOCKS5 server           │   │ Zscaler Client Connector   │       │
│  │ (3proxy / danted /      │──▶│ (tunnels to ZIA/ZPA)       │──▶ Zscaler cloud → internet
│  │  custom tiny server)    │   └────────────────────────────┘       │
│  │  binds 0.0.0.0:1080     │                                        │
│  └─────────────────────────┘                                        │
└─────────────────────────────────────────────────────────────────────┘
```

**Components**
- **Shunt.app (container, Swift/SwiftUI/AppKit)**: menu bar UI, settings, manages `NETransparentProxyManager`, activates system extension via `OSSystemExtensionRequest`, manages VM lifecycle (start/stop via `prlctl`/`vmrun`/`utmctl`).
- **ShuntProxyExtension (system extension)**: `NETransparentProxyProvider` subclass. Reads UserDefaults-shared config (via App Group), filters flows by `sourceAppSigningIdentifier`, forwards claimed flows to `127.0.0.1:1080` over SOCKS5.
- **VM (Windows 11 ARM)**: runs Zscaler Client Connector + a SOCKS5 server (e.g. [3proxy](https://github.com/3proxy/3proxy) or a small custom server) bound to `0.0.0.0:1080` inside the guest; hypervisor forwards host `127.0.0.1:1080` → guest `:1080`. Zscaler handles the DNS and routing of SOCKS-forwarded traffic as if it originated from the VM.

**Top 3 risks and mitigations**
1. **UDP/QUIC via SOCKS5 is finicky.** SOCKS5 UDP ASSOCIATE requires the client to send UDP datagrams to a secondary port the server returns. Many SOCKS servers implement it half-heartedly. *Mitigation:* pick a server with tested UDP support (3proxy has it). Fallback: fall back to TCP for Teams signaling and let Teams media go direct (document this behavior — many corporate Teams setups already tolerate direct media for call quality).
2. **Entitlement approval could take weeks.** *Mitigation:* file request immediately at the start of dev; in parallel, implement against ad-hoc-signed local dev builds using the "run unsigned system extension with SIP tweaks" dev flow (`systemextensionsctl developer on`). PoC Option B (Section 5.2) is usable during wait.
3. **VM boot time adds latency to first corp-app launch.** A cold Windows ARM VM takes ~20–40s to be "SOCKS-ready". *Mitigation:* Shunt's "Corporate mode ON" action boots the VM first and waits on a health-check (TCP probe to `127.0.0.1:1080`) before letting the user launch Teams, just like zOFF's tunnel readiness poll.

**Effort estimate:** 3–5 weeks of focused work after entitlement approval, split roughly:
- 3–4 days: container app scaffolding (menu bar, settings, observable state) — largely portable from zOFF.
- 1 week: system extension + SOCKS5 client flow pumping. Core loop + UDP.
- 3–5 days: VM lifecycle orchestration (Parallels/VMware CLI wrapper, boot health checks).
- 3–5 days: VM-side SOCKS5 server setup + Zscaler readiness detection scripts.
- 1 week: polish (onboarding UX, error recovery, notarization pipeline, logging).

### 5.2 Option B (fallback) — PAC + SOCKS5 (no entitlements)

```
┌────────────────────────────────────────┐
│  macOS host                            │
│                                        │
│  Teams.app    ───(ignores PAC mostly)──X (works via direct, no Zscaler)
│  Outlook.app  ──(partly honors PAC)───▶ via SOCKS5
│  Safari/Browsers ─(honors PAC)────────▶ PAC decides direct or SOCKS5
│                                        │
│  System Proxy Auto Config (PAC)        │
│    networksetup -setautoproxyurl ...   │
│    PAC decides per-URL:                │
│      if host matches corp → SOCKS5     │
│      else → DIRECT                     │
│                                        │
│  SOCKS5 destination: 127.0.0.1:1080    │
│                 │                      │
│                 ▼                      │
│         (hypervisor port-forward)      │
└────────────────┬───────────────────────┘
                 ▼
        VM with Zscaler + SOCKS5 server  (same as Option A)
```

**Components**
- Shunt.app container only — no system extension.
- A small HTTP server inside Shunt (e.g. using `Network.framework` NWListener) serves the PAC file at `http://127.0.0.1:<ephemeral>/shunt.pac`.
- On "Corporate mode ON", Shunt calls `networksetup -setautoproxyurl <service> <url>` and `-setautoproxystate <service> on` for each active network service (needs one-shot admin auth, same pattern as zOFF).
- VM runs SOCKS5 + Zscaler as in Option A.

**Top 3 risks and mitigations**
1. **Teams and new Outlook largely ignore system proxy.** *Mitigation:* document honestly that Option B covers browser-based corp access (SharePoint in Safari, Teams-on-web, OWA) but not the native Teams/Outlook clients. Ship it as a "Lite" mode.
2. **No UDP / no QUIC.** *Mitigation:* none — this mechanism fundamentally cannot carry QUIC. Apps that require QUIC will fall back to TCP-only where possible, or break.
3. **Global side-effects.** PAC is system-wide per network service. *Mitigation:* the PAC function checks destination, not origin; write it to only proxy known corp hostnames so personal traffic goes DIRECT. Always-restore on toggle OFF.

**Effort estimate:** 1–1.5 weeks. Reuses zOFF's patterns for admin privilege + networksetup calls.

---

## Section 6 — PoC validation plan (1 day)

**Goal:** Prove end-to-end that traffic can be forced from the host through a SOCKS5 endpoint inside the Windows VM, egress via Zscaler, and be distinguishable from host-direct traffic. No macOS entitlements needed. No code written yet.

### 6.1 VM-side setup (~1 hour)

1. In the existing Windows VM: download and install [3proxy](https://github.com/3proxy/3proxy/releases) (ARM64 build) or [Dante](https://www.inet.no/dante/) if Linux-guest.
2. Minimal `3proxy.cfg`:
   ```
   nserver 8.8.8.8
   nscache 65536
   auth none
   socks -p1080 -i0.0.0.0
   ```
3. Start as service. Verify from inside VM: `curl --socks5 127.0.0.1:1080 https://ifconfig.me/ip` — expect Zscaler egress IP (different from your ISP's).
4. In Parallels/VMware, add a host→guest NAT port forward: host `127.0.0.1:1080` → guest `<VM IP>:1080`. Parallels: `prlsrvctl net set Shared --nat-tcp-add shunt-socks,1080,<VM-NAME>,1080`. VMware: edit `/Library/Preferences/VMware Fusion/vmnet8/nat.conf`, add `[incomingtcp] 1080 = <VM IP>:1080`, restart vmnet.

### 6.2 Host-side verification (~15 minutes)

From the Mac host (no Shunt code yet, just curl):

```
# Expect Zscaler egress IP (same as observed inside the VM)
curl --socks5-hostname 127.0.0.1:1080 https://ifconfig.me/ip

# Expect ISP egress IP (your normal home IP)
curl https://ifconfig.me/ip

# DNS behavior: --socks5-hostname tunnels DNS through Zscaler's resolver
curl --socks5-hostname 127.0.0.1:1080 https://<corporate-only-intranet-hostname>/
```

**Success criteria at this step:**
- The two `ifconfig.me` results return **different IPs**.
- Corporate-only hostname resolves and responds through the SOCKS path, fails direct.

### 6.3 Minimal host-side interception PoC (~1–2 hours)

Use the simplest available mechanism that doesn't require NetworkExtension:

**Option 6.3.a — `proxychains4` wrapper** (CLI only, very easy):
- `brew install proxychains-ng`.
- Configure `~/.proxychains/proxychains.conf` with `socks5 127.0.0.1 1080`.
- Run a corp CLI tool: `proxychains4 curl https://<corp-intranet>/api`.
- This is **not** useful for GUI apps (Teams/Outlook ignore DYLD interpositioning signals and macOS hardened runtime blocks proxychains for many binaries), but it proves the forwarding path works for CLI.

**Option 6.3.b — System-wide PAC** (GUI path, matches Option B in Section 5):
- Create `/tmp/shunt.pac`:
  ```
  function FindProxyForURL(url, host) {
      if (dnsDomainIs(host, ".corp.example.com") || host == "outlook.office.com")
          return "SOCKS5 127.0.0.1:1080";
      return "DIRECT";
  }
  ```
- `python3 -m http.server 8787 --directory /tmp` in a terminal.
- `sudo networksetup -setautoproxyurl Wi-Fi http://127.0.0.1:8787/shunt.pac`
- `sudo networksetup -setautoproxystate Wi-Fi on`.
- Open Safari, hit corp intranet — should succeed. Hit google.com — should go direct.
- Open Teams desktop — observe whether it honored the PAC (likely: partial/no).
- Cleanup: `sudo networksetup -setautoproxystate Wi-Fi off`.

### 6.4 Success criteria for the day

- [ ] SOCKS5 endpoint inside VM reachable from host at `127.0.0.1:1080`.
- [ ] Traffic through SOCKS5 egresses via Zscaler (distinct IP from direct traffic).
- [ ] CLI tool via `proxychains4` can reach corp-internal hosts.
- [ ] Safari honors PAC; direct traffic bypasses; Teams observed (good or bad) as baseline.
- [ ] Zero config leaks: `curl https://ifconfig.me/ip` without SOCKS still returns ISP IP, not Zscaler IP.

Once this PoC passes, the technical foundation is validated and the only remaining work is the native mechanism (Transparent Proxy) for GUI app coverage + entitlement paperwork.

---

## Section 7 — Open questions for the user

### 7.1 Decisions made (2026-04-20)

- **Guest OS long-term:** **macOS guest on Apple Virtualization Framework.** User has a macOS installer and license. AVF is the lightest option on Apple Silicon (native arm64, ~3-4 GB RAM idle, Swift-native lifecycle via `Virtualization.framework`). Zscaler macOS Client Connector works here; user is responsible for verifying licensing permits enrolling the guest as an additional device. Tooling: likely [VirtualBuddy](https://github.com/insidegui/VirtualBuddy) or [Tart](https://github.com/cirruslabs/tart) for the PoC; Shunt may later embed `Virtualization.framework` directly.
- **Guest OS PoC:** Existing Windows 11 ARM VM with Zscaler already installed — used as-is, zero setup friction. Goal of PoC is validating the host-side interception, not the guest.
- **Hypervisor fallback:** If Zscaler on macOS guest hits licensing or technical issues, fall back to **Parallels + Windows 11 ARM** (user has Parallels license). VMware Fusion not planned.
- **Teams media routing:** Default to routing ALL Teams traffic via Zscaler for correctness. Expose a "Bypass Teams media" toggle in Settings → Advanced (off by default) once voice/video quality is measured on real calls.
- **Distribution:** Developer ID + notarization. No App Store.

### 7.2 Still open

1. **Zscaler licensing for macOS guest VM.** User to verify with corporate IT or Zscaler docs whether enrolling the macOS guest as an additional device is permitted. Does not block PoC (PoC uses the Windows VM that is already enrolled).
2. **List of corporate apps** beyond Teams and Outlook to route by default. Candidates: OneDrive, SharePoint sync, Company Portal, Defender for Endpoint, Microsoft Edge (corporate SSO), corporate IDE/Git client.
3. **Behavior when VM is not running.** When a managed app tries to connect and VM is down: (a) block flow with a user notification, (b) auto-start the VM and wait, (c) fail-open (route direct). Recommended: auto-start, wait up to 60s, then block on timeout.
4. **Posture/compliance.** Does corporate Zscaler tenant apply ZDX device-posture checks that could reject a VM-based enrollment or flag multi-device-same-user patterns?
5. **SOCKS server inside VM.** Default recommendation: **3proxy** (battle-tested, tiny, simple config). Alternative: write a small Swift/Rust UDP-aware SOCKS5 server for tighter control.
6. **Telemetry/logging posture.** Shunt has flow-level data available (bundle ID, bytes per flow). Inherit zOFF's strict local-only stance, or surface per-app bandwidth in the UI?
7. **App Group identifier** for sharing config between `Shunt.app` and `ShuntProxy` system extension. Suggested: `group.com.craraque.shunt`.
8. **Default DNS policy for claimed flows.** `--socks5-hostname` (remote DNS via Zscaler — recommended, so Zscaler sees hostnames for its policy engine) vs local DNS (host resolves, forwards IP).

---

## Appendix A — Key Apple doc links

- [NETransparentProxyProvider](https://developer.apple.com/documentation/NetworkExtension/NETransparentProxyProvider)
- [NETransparentProxyManager](https://developer.apple.com/documentation/networkextension/netransparentproxymanager)
- [NEAppProxyProvider](https://developer.apple.com/documentation/networkextension/neappproxyprovider)
- [NEAppProxyFlow](https://developer.apple.com/documentation/networkextension/neappproxyflow)
- [NEAppProxyTCPFlow](https://developer.apple.com/documentation/networkextension/neappproxytcpflow)
- [NENetworkRule](https://developer.apple.com/documentation/networkextension/nenetworkrule)
- [Network Extension Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension)
- [Configuring Network Extensions (Xcode)](https://developer.apple.com/documentation/xcode/configuring-network-extensions)
- [WWDC19 Session 714 — Network Extensions for the Modern Mac](https://developer.apple.com/videos/play/wwdc2019/714/)
- [Notarizing macOS Software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Developer ID signing](https://developer.apple.com/developer-id/)
- [Apple Virtualization Framework](https://developer.apple.com/documentation/virtualization)
- [VZBridgedNetworkInterface](https://developer.apple.com/documentation/virtualization/vzbridgednetworkinterface)

## Appendix B — Key third-party references

- [Zscaler Client Connector platform](https://www.zscaler.com/products-and-solutions/zscaler-client-connector)
- [Zscaler ZCC Windows ARM partnership](https://www.zscaler.com/blogs/product-insights/zscaler-partners-microsoft-secure-lte-arm-devices)
- [Zscaler ZCC LTS 2026](https://www.zscaler.com/blogs/product-insights/long-term-support-zscaler-client-connector)
- [Zscaler macOS user guide](https://help.zscaler.com/zpa/zscaler-client-connector/zscaler-client-connector-user-guide-macos)
- [Parallels CLI reference](https://docs.parallels.com/parallels-desktop-developers-guide/command-line-interface-utility/manage-virtual-machines-from-cli/general-virtual-machine-management/power-operations)
- [Parallels headless KB](https://kb.parallels.com/en/123298)
- [VMware Fusion free-for-personal announcement (Macworld)](https://www.macworld.com/article/668848/best-virtual-machine-software-for-mac.html)
- [vmrun headless helper](https://github.com/alexdotsh/vmruncli)
- [UTM port-forwarding docs](https://docs.getutm.app/settings-qemu/devices/network/port-forwarding/)
- [Tart (Cirrus Labs)](https://tart.run/) · [Tart GitHub](https://github.com/cirruslabs/tart)
- [VirtualBuddy](https://github.com/insidegui/VirtualBuddy)
- [3proxy](https://github.com/3proxy/3proxy)
- [SimpleFirewall (Apple sample, NE)](https://github.com/cntrump/SimpleFirewall)
- [proxy-nio (Swift SOCKS5)](https://github.com/purkylin/proxy-nio)
- [macOS pf manual (Murus)](https://murusfirewall.com/Documentation/OS%20X%20PF%20Manual.pdf)
- [Teams proxy handling reports](https://learn.microsoft.com/en-us/answers/questions/467351/ms-teams-isnt-respecting-proxy-settings)
- [WWDC19 714 transcript](https://asciiwwdc.com/2019/sessions/714)

## Appendix C — Glossary

- **AVF** — Apple Virtualization Framework (`Virtualization.framework`, macOS 11+, native arm64 VM host).
- **ZCC** — Zscaler Client Connector, the endpoint agent that tunnels user traffic to Zscaler cloud (ZIA/ZPA).
- **ZIA** — Zscaler Internet Access. **ZPA** — Zscaler Private Access.
- **Transparent Proxy (NE)** — Network Extension provider type that decides per-flow to claim-or-passthrough without modifying non-claimed flows.
- **System Extension** — post-kext user-space extension mechanism; the distribution shell for modern Network Extensions on macOS.
- **NEAppRule** — a rule that binds a provider to specific signing identifiers (legacy / per-app VPN model).
- **`sourceAppSigningIdentifier`** — the bundle identifier Shunt matches against to decide claim/passthrough.
- **SOCKS5 UDP ASSOCIATE** — the SOCKS5 sub-protocol for tunneling UDP datagrams; required for QUIC/Teams media over a proxy.
- **Notarization** — Apple's automated malware-scan for Developer ID-signed apps; required for macOS Gatekeeper to not warn on first run.
