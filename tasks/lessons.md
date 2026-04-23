# Lessons

## 2026-04-21 (next session) — `IP_BOUND_IF` via `setsockopt` is the sanctioned bypass for NECP interface scoping

**What finally worked.** Earlier lesson (line below) concluded NE-provider outbound NWConnection/createTCPConnection are scoped to the primary NIC and BSD POSIX sockets bypass this. That's only half true: a raw BSD socket still picks the primary interface via the routing table. To actually reach bridge100 (Parallels shared network), call `setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &ifIndex, size)` right after `socket()` and before `connect()`. `ifIndex` comes from `if_nametoindex("bridge100")`.

**Code.** In `POSIXTCPClient.doConnect`:
```swift
if let ifName = bindInterface {
    let idx = if_nametoindex(ifName)
    var value = UInt32(idx)
    let opt: Int32 = info.pointee.ai_family == AF_INET6 ? IPV6_BOUND_IF : IP_BOUND_IF
    let level: Int32 = info.pointee.ai_family == AF_INET6 ? IPPROTO_IPV6 : IPPROTO_IP
    setsockopt(fd, level, opt, &value, socklen_t(MemoryLayout<UInt32>.size))
}
```

**Rule for Claude.** Reference: Apple DTS (Quinn) forum thread 736083. For IPv4 use `IP_BOUND_IF` at `IPPROTO_IP`; for IPv6 use `IPV6_BOUND_IF` at `IPPROTO_IPV6`. Always pick based on `addrinfo.ai_family` from getaddrinfo so the code works for both address families.

## 2026-04-21 (next session) — macOS system extensions must be activated from an app under `/Applications`

**What went wrong.** Running `build/Shunt.app/Contents/MacOS/Shunt --auto-activate` from the build directory: `OSSystemExtensionErrorDomain error 3` with message "App containing System Extension to be activated must be in /Applications folder. Current location: file:///Users/cesar/dev/shunt/build/Shunt.app/".

**Correction.** `build.sh` produces the app at `build/Shunt.app` (notarized+stapled), but activation must be from `/Applications/Shunt.app`. Either copy after build or add a post-build step. For dev iteration: `rm -rf /Applications/Shunt.app && cp -R build/Shunt.app /Applications/Shunt.app` — Gatekeeper assessment survives the copy as long as the quarantine attribute isn't set.

**Rule for Claude.** When documenting/scripting activation of a system extension during dev, always `cp -R` from build/ to /Applications/ first. The documented requirement applies even in `systemextensionsctl developer on` mode.

## 2026-04-21 (late session) — `transparent-proxy-systemextension` is a PHANTOM entitlement; NETransparentProxyProvider uses `app-proxy-provider-systemextension` + `.app-proxy` Info.plist key

**What was wrong for hours.** The entire first half of the session was wasted chasing an entitlement that doesn't exist. `transparent-proxy-systemextension` circulates in AI training data, older forum posts, and Shunt's original `docs/RESEARCH.md` — but Apple's current public entitlement reference (enumerating ALL possible values for `com.apple.developer.networking.networkextension`) does not contain it. The value simply does not exist in the public API.

**Root cause.** `NETransparentProxyProvider` is a Swift subclass of `NEAppProxyProvider`. They share the same entitlement value (`app-proxy-provider` for Mac App Store, `app-proxy-provider-systemextension` for Developer ID) AND the same Info.plist NEProviderClasses key (`com.apple.networkextension.app-proxy`). The word "transparent" refers to runtime behavior (flow diversion without NEAppRule; returning `false` passes through untouched) — NOT to a distinct entitlement or extension-point identifier.

**Confirmed by three independent production apps** that ship Developer-ID-signed NETransparentProxyProvider extensions today: madeye/BaoLianDeng, pia-foss/mac-split-tunnel, mitmproxy/mitmproxy_rs. All three use exactly:
- Swift class: `NETransparentProxyProvider`
- Entitlement: `[app-proxy-provider-systemextension]`
- Info.plist key: `com.apple.networkextension.app-proxy`

Apple's own TN3134 "Network Extension provider deployment" confirms transparent proxy as a system extension is Developer-ID-eligible (no "App Store only" restriction on that row).

**Rule for Claude.** For any Apple entitlement or capability claim in older docs/forums:
1. VERIFY against Apple's current entitlement reference page by fetching the live JSON (DocC at `/tutorials/data/documentation/bundleresources/entitlements/*.json`). If the value isn't in the official enumeration, it doesn't exist.
2. Look at open-source production apps (GitHub search for the class name + language:Swift). If multiple production apps are shipping with a different entitlement than the AI/forums claim, trust the production apps.
3. "Transparent Proxy" (the feature) vs `transparent-proxy-systemextension` (the entitlement) — the feature is real, the entitlement name is folklore. Always double-check by grepping Apple's entitlement reference JSON for the exact string before committing.

**Rule for NE provider class selection on macOS Developer ID:**
- `NETransparentProxyProvider` subclass: use for per-app runtime filtering (filter in handleNewFlow). No NEAppRule.
- `NEAppProxyProvider` direct subclass: use for NEAppRule-based per-app VPN semantics. Has known breakage on own-team Developer-ID target apps.
- Both use the same entitlement (`app-proxy-provider-systemextension`) and Info.plist key (`com.apple.networkextension.app-proxy`).
- Recommendation: default to `NETransparentProxyProvider` for macOS Developer ID per-app proxying. Quinn (Apple DTS, thread 131815) explicitly: *"most developers use a content filter provider or a transparent proxy provider rather than app proxy providers."*

**Debug-time watchpoint.** If sysextd logs say "invalid extension point in its NetworkExtension Info.plist key: com.apple.networkextension.transparent-proxy" → the Info.plist key is wrong. Change to `.app-proxy`. (The key mirrors the entitlement value family, NOT the specific Swift subclass you implement.)

## 2026-04-21 — Developer ID apps with restricted entitlements need embedded provisioning profiles

**What went wrong.** Built Shunt.app signed with Developer ID Application cert + notarized successfully. Launching it from `/Applications` failed with POSIX 163 / launchd spawn failed. Direct execution: SIGKILL with exit 137.

**Root cause.** `amfid` logged `"No matching profile found"` and `"Code has restricted entitlements, but the validation of its code signature failed"`. The entitlement `com.apple.developer.networking.networkextension = [transparent-proxy-systemextension]` is *restricted* — macOS requires a provisioning profile embedded at `Contents/embedded.provisionprofile` to prove the Team ID is authorized for that specific bundle ID and entitlement. Notarization alone does not authorize; the profile does.

**Correction.** Create a Developer ID provisioning profile per bundle ID at developer.apple.com → Profiles → "+" → Distribution: **Developer ID** → pick App ID → pick Developer ID Application cert → download. Embed each `.provisionprofile` into its respective bundle during `build.sh`. Sign AFTER embedding (codesign hashes the profile into the signature).

**Rule for Claude.** For any macOS Developer ID distribution that touches a restricted entitlement (Network Extensions, Endpoint Security, DriverKit, etc.), embedding a matching provisioning profile is mandatory. Do NOT assume notarization + Developer ID cert is sufficient — the profile is a separate authorization artifact. In build scripts, copy profile → embed → sign (in that order).

## 2026-04-20 — transparent-proxy-systemextension is NOT a managed capability

**What went wrong.** RESEARCH.md §4.4 (written based on older Apple docs) said we needed to email `developer.apple.com/contact/network-extension` and wait 1-4 weeks. Prepared a draft and was about to send it.

**Root cause.** Apple consolidated the capability-request flow. Most Network Extension provider values (including `transparent-proxy-systemextension`) stopped being "managed" in November 2016. The old `/contact/network-extension` URL now redirects to `/contact/request/hotspot-helper/` because Hotspot Helper is one of the few NE values still managed. The new managed-capability request flow lives in a "Capability Requests" tab on each App ID in Certificates, Identifiers & Profiles — and Network Extensions does NOT appear there.

**Correction.** Check the Capability Requests tab on the App ID first. If Network Extensions is absent from that tab, it's auto-granted via the regular Capabilities tab — no request needed.

**Rule for Claude.** For any entitlement in a >2-year-old research doc, re-verify the current request process before telling the user to wait weeks. Apple's capability taxonomy moves; yesterday's "managed capability" is today's "just enable it".

## 2026-04-21 — `transparent-proxy-systemextension` is NOT available to Developer ID distribution at all; must use NEAppProxyProvider instead

**What went wrong.** After fixing entitlement/profile mismatch, sysextd rejected with "System extension has an **invalid extension point** in its NetworkExtension Info.plist key: `com.apple.networkextension.transparent-proxy`". The value `transparent-proxy-systemextension` was missing from the Developer ID provisioning profile's allowed-entitlements array. The Capabilities tab in the portal has no sub-options for Network Extensions — it's a plain checkbox. The Capability Requests tab has no Transparent Proxy entry either. Per Apple DTS engineer Matt Eaton (forum thread 664126), the five values Developer ID profiles grant are: `packet-tunnel-provider-systemextension`, `app-proxy-provider-systemextension`, `content-filter-provider-systemextension`, `dns-proxy-systemextension`, `dns-settings`. `transparent-proxy-systemextension` is not on that list and cannot be requested via the public UI.

**Root cause.** Apple scoped NETransparentProxyProvider to Mac App Store distribution. For Developer ID distribution of a per-app proxy, the available API is NEAppProxyProvider (Transparent Proxy's parent class). Their handleNewFlow APIs are structurally similar; the main user-visible difference is that NEAppProxyProvider creates a VPN-like entry in Network Preferences while NETransparentProxyProvider does not.

**Correction.** Switched ShuntProxyProvider's base class from `NETransparentProxyProvider` to `NEAppProxyProvider`, and the Info.plist NEProviderClasses key from `com.apple.networkextension.transparent-proxy` to `com.apple.networkextension.app-proxy`. Entitlement value stays `app-proxy-provider-systemextension`. Startup code also changed — NEAppProxyProvider's startProxy doesn't use NETransparentProxyNetworkSettings (that class is specific to NETransparentProxyProvider); just call completionHandler(nil).

**Rule for Claude.** Before committing to `NETransparentProxyProvider`, check whether the distribution channel is Mac App Store. For Developer ID distribution, default to `NEAppProxyProvider`. Same pattern applies if the user later pays for DTS support and Apple grants the transparent-proxy entitlement — but don't assume that path; plan for the App Proxy fallback from day one.

## 2026-04-21 — For Developer ID NETransparentProxyProvider, the entitlement VALUE is `app-proxy-provider-systemextension`, not `transparent-proxy-systemextension` (now superseded by lesson above)

**What went wrong.** After embedding provisioning profiles, `amfid` still killed Shunt on launch: "1 unsatisfied entitlement". Inspecting the embedded profile showed the NE array permitted `packet-tunnel-provider-systemextension`, `app-proxy-provider-systemextension`, `content-filter-provider-systemextension`, `dns-proxy-systemextension`, `dns-settings`, `relay`, `url-filter-provider`, `hotspot-provider` — but NOT the `transparent-proxy-systemextension` value that our entitlements file declared. The profile doesn't authorize that value, and Apple's portal does not offer a way to add it.

**Root cause.** `NETransparentProxyProvider` inherits from `NEAppProxyProvider`. For historical Apple-compat reasons, the entitlement value for Developer-ID-signed system extensions that use either provider class is `app-proxy-provider-systemextension`. The `transparent-proxy-systemextension` value only exists for the Mac App Store path. Apple's own docs on `NETransparentProxyProvider` say "use transparent-proxy-systemextension", but that guidance applies to App Store; Developer ID uses the App Proxy value. This is an acknowledged inconsistency in Apple's docs (multiple DTS forum posts reference it).

**Correction.** Change `transparent-proxy-systemextension` → `app-proxy-provider-systemextension` in both `Shunt.entitlements` and `ShuntProxy.entitlements`. No change needed in the Info.plist `NEProviderClasses` key (that stays as `com.apple.networkextension.transparent-proxy` → `ShuntProxy.ShuntProxyProvider` because that maps Swift classes to provider type, not the entitlement value).

**Rule for Claude.** When planning entitlements for a macOS system extension with NETransparentProxyProvider or NEAppProxyProvider:
- **Developer ID distribution:** entitlement value is `app-proxy-provider-systemextension` (both classes use this).
- **Mac App Store:** `app-proxy-provider` (older) or `transparent-proxy-systemextension` if available.
- When the embedded profile's NE array doesn't contain the value your entitlements request, the entitlement choice is wrong — not the profile.
- Always inspect profile entitlements before coding: `security cms -D -i <profile>.provisionprofile` and confirm the declared entitlement value is in the allowed array.

## 2026-04-21 — NEAppRule matchDomains: required for third-party apps, forbidden for own-team apps

**What went wrong.** Two opposite errors hit us in the same session. First rule save with Safari + no matchDomains: `NEVPNErrorDomain 1 "At least one match domain or match account identifier is required for this app rule"`. Added `matchDomains`, worked for Safari. Later switched to our own Developer-ID-signed test CLI (`com.craraque.shunt.test`) and the same code paths failed: `NEVPNErrorDomain 1 "App rule matching com.craraque.shunt.test cannot have matchDomains or matchAccountIdentifiers"`.

**Root cause.** macOS NEAppRule validates matchDomains differently based on whether the signingIdentifier belongs to a **third-party / Apple-platform** app vs an **own-team app** (signed by the same Team ID that owns the VPN config). Third-party apps need matchDomains to prove scoped intent. Own-team apps are trusted across all domains by default, and specifying matchDomains is rejected as redundant/contradictory.

**Rule for Claude.** Detect the signingIdentifier's team. For own-team Developer-ID apps (same Team ID as the VPN config owner), set `appRule.matchDomains = nil`. For third-party apps (Apple's or other teams'), matchDomains is mandatory — use a concrete list or a catch-all that matches app behavior.

## 2026-04-21 — NEAppRule.designatedRequirement must EXACTLY match the binary's actual DR string

**What went wrong.** Used a simplified designated requirement string in NEAppRule: `identifier "com.craraque.shunt.test" and anchor apple generic and certificate leaf[subject.OU] = "6NSZVJU6BP"`. Save succeeded. Binary runs. But flows from the binary are NOT diverted to the tunnel — ShuntTest egresses via home ISP instead of through the proxy.

**Root cause.** NEAppRule compares the configured designatedRequirement against the binary's signature using string/structural identity, not requirement satisfaction semantics. The actual DR that `codesign -d -r-` prints for a Developer-ID-signed binary includes Developer-ID-specific certificate marker OIDs (`certificate 1[field.1.2.840.113635.100.6.2.6]` and `certificate leaf[field.1.2.840.113635.100.6.1.13]`) that a simpler DR lacks. If these don't match exactly, the rule still saves (macOS validates the DR syntax, not its match against any binary), but at flow-divert time the kernel compares signatures and the rule silently doesn't fire.

**Correction.** Copy the DR string verbatim from `codesign -d -r- /path/to/app`. For Developer ID:
```
identifier "bundle.id" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "TEAMID"
```

**Rule for Claude.** Never write a designated requirement by hand. Always either (a) run `codesign -d -r-` on the signed binary and paste the output verbatim, or (b) construct via `SecRequirementCreateWithString` with a canonical form derived from the same source.

## 2026-04-21 — NEAppProxyProvider outbound connections are NIC-scoped, can't reach Parallels VM

**What went wrong.** NE provider tries to connect TCP to `10.211.55.5:1080` (Parallels shared-network VM). `nc -zv` from the host succeeds in <1ms. But NWConnection (Network framework) and `NEProvider.createTCPConnection` (NetworkExtension) both end up with their connection **scoped to en9** (WiFi, 192.168.101.x) — the primary active network interface — rather than bridge100 (Parallels virtual bridge, 10.211.55.x). SYN packets go out en9, never see 10.211.55.5. KVO on NWTCPConnection.state never leaves `.connecting`.

**Root cause.** NE system extensions run under tunnel-scope networking: all outbound connections they initiate are marked with the primary-interface scope to avoid routing loops. `bridge100` is a virtual bridge for a non-default interface; the scope policy doesn't pick it.

**Workaround.** Use POSIX BSD sockets directly — `socket()` / `connect()` / `send()` / `recv()` — via `Darwin` module. BSD socket syscalls use the host's standard routing table without the NE scoping overlay. Confirmed in earlier PoC (`nc`, `curl`) that bridge100 is reachable via the default route.

**Rule for Claude.** For any NE system extension that needs to reach an address on a non-primary network interface (VM network, VLAN, alternate NIC), use POSIX sockets via `Darwin`. Do not trust that `NEProvider.createTCPConnection` or `Network.NWConnection` will route via the standard table.

## 2026-04-21 — Sysextd leaves zombie terminated extensions that pile up on each build

**What went wrong.** Every `./Scripts/build.sh notarize` produces a new CFBundleVersion (timestamp). After 8+ iterations, `systemextensionsctl list` shows 8+ entries in `[terminated waiting to uninstall on reboot]` state. Each rebuild activates the new version and marks the old one for uninstall, but the old extension's process often keeps running as long as it had a VPN session attached. When we kill the main app, the VPN session persists internally and the old provider continues.

**Root cause.** System extensions can't be killed with `pkill -9` without root (they run as root, owned by `nobody`). `sysextd` only cleans up "terminated" ones on reboot. The running provider process may still have pending `NEFlowDivertSession` clients even after the main app is gone, preventing graceful shutdown.

**Correction for dev workflow.**
- Before shipping: reboot to clean up, then bundle-version should be stable (e.g. derived from semver, not timestamp).
- Intra-session: each test cycle should ideally be a deactivationRequest followed by activationRequest — forces sysextd to stop and restart. NOT done in this session (we always just replaced).
- Between sessions: reboot to clean terminated extensions.

**Rule for Claude.** When iterating on a system extension, add a `--deactivate` flag to the main app that submits an OSSystemExtensionRequest.deactivationRequest. Use it at the end of every test cycle to leave a clean state. Also: the VPN config (NEAppProxyProviderManager preferences) persists independently of the extension — add a `--remove-config` flag too. Users shouldn't have to reboot or dig through System Settings between dev iterations.

## 2026-04-22 — `ForEach($array)` crashes with Array._checkSubscript when the array mutates during a view update

**What went wrong.** Shunt's Rules tab used `ForEach($rule.apps) { $app in RuleAppRow(app: $app, onCommit: { onEnrichApp(app.id) }, ...) }`. User clicked a TextField inside RuleAppRow, committed → `onCommit` called `model.enrichAppInRule` → the model mutated `settings.rules[i].apps[j]` → @Published fired → SwiftUI re-ran RuleCard.body2 during a layout pass → the still-alive `ForEach($rule.apps)` closure tried to read `app.id` via the per-element binding → that binding subscripts `rule.apps[index]` internally by **index** → index briefly invalid → `Array._checkSubscript` → `assertionFailure` → `EXC_BREAKPOINT` → crash.

Stack top:
```
Array._checkSubscript(_:wasNativeTypeChecked:)
Array.subscript.read
Binding<A>.subscript.getter (closure)
LocationBox.get()
Binding.readValue()
getter of `app` in closure in RuleCard.body2
```

**Root cause.** `ForEach($bindingArray) { $element in ... }` creates per-element bindings that internally subscript the array by index. The index captures at the time of ForEach construction, but is read (not re-resolved) at every body re-evaluation. If the array mutates between view graph construction and any subsequent binding read (typical during `save()` triggered by a TextField commit), the index is stale.

**Correction.** Iterate by value and construct ID-based bindings explicitly:

```swift
ForEach(rule.apps) { app in
    let appID = app.id                              // snapshot id
    RuleAppRow(
        app: appBinding(id: appID, fallback: app),  // ID-based Binding
        onCommit: { onEnrichApp(appID) },           // closure uses snapshot, not app
        onRemove: { onRemoveApp(appID) }
    )
}

private func appBinding(id: UUID, fallback: ManagedApp) -> Binding<ManagedApp> {
    Binding(
        get: { rule.apps.first(where: { $0.id == id }) ?? fallback },
        set: { newValue in
            if let idx = rule.apps.firstIndex(where: { $0.id == id }) {
                rule.apps[idx] = newValue
            }
        }
    )
}
```

The fallback is a stale-but-valid `ManagedApp` value used only in the brief window where the element was removed from the array — prevents the binding.get from trapping. The set path does nothing if the id is no longer present. The closures capture the snapshotted `appID` UUID, not the `app` value whose backing storage may evaporate.

**Rule for Claude.** In any SwiftUI view where a mutable array of Identifiable values is rendered AND individual items can trigger model mutations (TextField commit, Toggle change, onTap that calls save()):
1. Do NOT use `ForEach($array) { $item in ... }`. That's a crash waiting to happen.
2. Use `ForEach(array) { item in ... }` (by value, Identifiable) and build a custom `Binding<Item>` keyed by id for any child that needs two-way binding.
3. Capture the id as a local `let` at the top of the ForEach closure, and pass the id (not the value) into all callback closures.
4. Provide a `fallback: Item` in the get-side so a transient "not found" doesn't crash — the UI will briefly show stale data, then the enclosing view re-renders with the updated array.

This pattern is resilient to array reorder, removal, and addition during simultaneous view updates.

## 2026-04-22 — NavigationSplitView silently fails to render inside a custom NSWindow (LSUIElement app)

**What went wrong.** Replaced `TabView` with `NavigationSplitView` in `SettingsView.swift` for the v0.2 sidebar layout (per DESIGN.md §Layout). Launched the app → window opened with title "Shunt Settings" and a visible column divider, but **both the sidebar list and detail pane rendered as empty black rectangles**. No crash, no logs, no errors. Process alive. User reported "same symptom as yesterday" — confirming this had been hit before and was the reason v0.1 shipped with `TabView` instead.

**Root cause.** `NavigationSplitView` relies on internal `NavigationStack`-style plumbing that requires a SwiftUI-native window host (`WindowGroup` / `Settings` scene / `MenuBarExtra.window`). Shunt hosts its Settings UI inside a plain `NSWindow` via `NSHostingController(rootView:)` owned by an `NSWindowController` — this is necessary because `LSUIElement=true` breaks the SwiftUI `Settings` scene (window silently fails to come forward). Inside that non-SwiftUI-owned window, `NavigationSplitView` lays out its columns but its children (`List` selection + `detail` closure) silently don't emit views. Confirmed empirically: same code works fine in a SwiftUI `App` scene.

**Correction.** Replace `NavigationSplitView` with a plain `HStack { sidebar; Divider(); detail }`. Build the sidebar as a custom `VStack` of `Button`-based row views using `@State` for selection. Wrap the sidebar's background in a minimal `NSViewRepresentable` around `NSVisualEffectView(material: .sidebar)` to preserve the native vibrancy DESIGN.md specifies. All layout constants (200pt sidebar, 14pt icon + 13pt label, 8pt/6pt row padding, amber 15% active fill) match DESIGN.md §Layout exactly — we lose nothing except the `NavigationSplitView` convenience.

**Rule for Claude.** In any LSUIElement menubar app that hosts SwiftUI inside a plain `NSWindow`:
1. Do NOT reach for `NavigationSplitView` / `NavigationStack` / `.navigationTitle` / `.toolbar` APIs — they assume a SwiftUI-owned window and fail silently.
2. Default to: plain `HStack` + custom sidebar rows + state-driven detail switch. It's more code but 100% deterministic.
3. For sidebar vibrancy, use `NSViewRepresentable` wrapping `NSVisualEffectView` with `material: .sidebar`, `blendingMode: .behindWindow`, `state: .active`.
4. If the window opens but appears empty, do NOT assume a crash — check with `ps aux | grep AppName`. A dead process is a crash; a live process with an empty window is a SwiftUI hosting issue.

## 2026-04-21 — codesign hangs silently when the private-key ACL requires user approval

**What went wrong.** First `codesign --sign "Developer ID ..."` invocation hung with no output. Multiple invocations stacked up; TaskStop killed them but the build looked broken.

**Root cause.** A freshly-imported Developer ID private key has an ACL that prompts the user every time a tool tries to use it. The prompt comes from SecurityAgent (a macOS system service) and can appear BEHIND other windows, making codesign look hung. Killing codesign dismisses the dialog without resolving it.

**Correction.** Tell the user to watch for the keychain dialog and click **Always Allow** (not just Allow — that only permits this one invocation and the next codesign call hangs again).

**Rule for Claude.** After any first codesign with a new identity, warn the user about the hidden keychain dialog in the same message as kicking off the build. Don't wait for them to discover it by seeing a hanging build.
