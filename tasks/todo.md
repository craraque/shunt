# Shunt — Plan

macOS native menu bar app for per-app conditional routing of traffic through a VM running Zscaler. BYOD Mac, Zscaler used only to access corporate resources.

Reference: `docs/RESEARCH.md` is the technical source of truth.

## Phase 0 — Research ✅

- [x] Technical research document (`docs/RESEARCH.md`, 666 lines)
- [x] Decisions made: Transparent Proxy System Extension, macOS guest via AVF long-term, Windows VM for PoC, Developer ID distribution

## Phase 1 — Apple Developer paperwork (user-facing, kick off immediately)

Runs in parallel to PoC. Apple entitlement takes 1–4 weeks.

- [ ] Verify Apple Developer Program membership is active (renew if lapsed, $99/yr)
- [ ] In Certificates, Identifiers & Profiles → register bundle IDs:
  - [ ] `com.craraque.shunt` (main app)
  - [ ] `com.craraque.shunt.proxy` (system extension)
- [ ] Create/verify **Developer ID Application** certificate (for signing outside App Store)
- [ ] Create App-specific password for notarytool; store with `xcrun notarytool store-credentials`
- [ ] Submit Network Extension entitlement request at <https://developer.apple.com/contact/network-extension> using the wording in RESEARCH.md §4.4
- [ ] Enable local dev mode: `sudo systemextensionsctl developer on` + reboot

## Phase 2 — PoC on existing Windows VM (no Shunt code yet) ✅

Goal: prove end-to-end that traffic forced from host through a SOCKS5 endpoint in the VM egresses via Zscaler and is distinguishable from host-direct traffic. See RESEARCH.md §6.

Results: `docs/poc-results.md`. Architecture validated 2026-04-20. Host ISP `71.229.98.157` vs Zscaler egress `165.225.223.34` when routed via VM. HTTP 200 against `graph.microsoft.com`. Latency overhead ~263 ms per fresh TLS connect.

- [x] Install 3proxy in the Windows VM (SOCKS5 on port 1080) — config in `poc/3proxy-minimal.cfg`
- [x] VM reachable directly at `10.211.55.5:1080` on Parallels shared network (no `prlsrvctl` port-forward required)
- [x] From host: `curl --socks5-hostname 10.211.55.5:1080 https://ifconfig.me` → Zscaler IP
- [x] Direct baseline: `curl https://ifconfig.me` → home ISP IP
- [x] `graph.microsoft.com` returns 200 OK via SOCKS5
- [x] Latency delta documented
- [ ] UDP ASSOCIATE verification (deferred — needs real Teams call, blocked on Phase 3 provider)

## Phase 3 — Native Swift app (menu bar) — starts after PoC passes

### Phase 3a — Build + sign + notarize + load + enable ✅ (2026-04-21)

End-to-end ciclo de carga del System Extension validado. `com.craraque.shunt.proxy` quedó en estado `[activated enabled]` tras aprobación del user en System Settings. Lecciones guardadas en `tasks/lessons.md`:
- Developer ID con restricted entitlements exige embedded.provisionprofile por bundle
- `transparent-proxy-systemextension` NO disponible en Developer ID; usar `app-proxy-provider-systemextension` + `NEAppProxyProvider`
- NEMachServiceName debe estar prefixed por un App Group registrado
- Pivot arquitectónico: NEAppProxyProvider (en vez de NETransparentProxyProvider) — misma funcionalidad, UX muestra entrada tipo VPN en Network preferences

- [x] Project scaffold: Swift Package Manager, Swift 5.10+, Apple Silicon, two targets (`Shunt`, `ShuntProxy`)
- [x] Skeleton SwiftUI + AppKit menu bar
- [x] Build+sign+load+enable round-trip working (SIP-on + Developer ID + notarization)
- [x] Ciclo autónomo: `./Scripts/run-and-watch.sh` + flag `--auto-activate` para iterar sin intervención manual

### Phase 3b — Flow interception ✅ (2026-04-21)

End-to-end validado: `ShuntTest` → `NETransparentProxyProvider.handleNewFlow` → `SOCKS5Bridge` (con `IP_BOUND_IF` bound a bridge100) → Parallels VM 10.211.55.5:1080 → Zscaler → `ipinfo.io/ip` retornó `165.225.223.34` (IP Zscaler). Host baseline `71.229.98.157` confirma que sólo el tráfico de ShuntTest se redirige.

- [x] `NETransparentProxyManager` config desde el main app (pivoteamos de NEAppProxyProvider tras deep research — Quinn/DTS thread 131815 explícito)
- [x] Provider `startProxy` invoca `setTunnelNetworkSettings` con `includedNetworkRules = 0.0.0.0/0 TCP+UDP`
- [x] `handleNewFlow`: filtra por `NEAppProxyFlow.metaData.sourceAppSigningIdentifier`; `return false` para pass-through en flows no-claimed
- [x] `ShuntTest` CLI + bundled app (`com.craraque.shunt.test`) firmado con Developer ID
- [x] `SOCKS5Bridge` + `POSIXTCPClient` con `setsockopt(IP_BOUND_IF, if_nametoindex("bridge100"))` para bypass NECP scoping
- [x] Validado: `ShuntTest` egreso Zscaler IP `165.225.223.34`
- [x] Validado con **Teams + Outlook reales** 2026-04-21: login, mail sync, chat, presencia, dos llamadas. Calls usan pass-through UDP (directo por ISP) — esto es feature, no bug (decisión de producto 2026-04-21: mejor latencia de calls vs purity de "todo por Zscaler"). No implementar SOCKS5 UDP ASSOCIATE.

### Phase 3b — Dev workflow fixes ✅

- [x] Flag `--deactivate` en main app (invoca `OSSystemExtensionRequest.deactivationRequest`)
- [x] Flag `--remove-config` en main app (llama `removeFromPreferences` en NETransparentProxyManager + NEAppProxyProviderManager legacy)
- [x] `CFBundleVersion` monotónico en `Scripts/.build-number` (reemplaza `date +%s`); override vía env var `BUILD_NUMBER`

### Phase 3c — Settings window (v0.1 MVP) ✅

- [x] Apps tab funcional (add/edit/remove bundle IDs)
- [x] Persistencia via App Group container (`settings.v1.json`)
- [x] Config compartida entre main app y extension vía App Group (`group.com.craraque.shunt`)
- [ ] Export/import JSON (deferred — not critical for v0.2)

### Phase 3d — v0.2: Compound rules, sidebar redesign, themes, UX fixes — 2026-04-22

Goal: evolve Shunt from "per-app routing" to "per-rule routing where a rule = (apps ∧ hosts → action)". Ship the sidebar layout that DESIGN.md has always specified (820×520). Add user-selectable themes. Fix two UX bugs reported during dogfooding.

#### 3d.1 — UX bug fixes (quick wins, ship first commit)

- [ ] **Fix icon rendering for bundle-ID-only entries**
  - `AppRow.icon` at `Sources/Shunt/Views/AppsTab.swift:145` falls back to placeholder when `app.appPath` is nil. Seeded test entries (Teams, ShuntTest) have `appPath = nil`, so no icon renders.
  - When `appPath` is nil, resolve via `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`; write back to `app.appPath` on success so next launch already has it.
  - Verification: launch, look at Teams row — icon should appear.
- [ ] **Fix "Add by Bundle ID" UX** (button appears to do nothing)
  - `addManualEntry()` at `AppsTab.swift:100-105` appends an empty row at the end. No scroll, no focus → from the user's perspective, nothing happens.
  - Add `ScrollViewReader` and `@FocusState` so that clicking the button scrolls the new row into view and focuses the bundle-ID TextField.
  - Drop the "New entry" display-name placeholder; let the TextField placeholder show "Display name".
  - On TextField commit of the bundle ID, auto-resolve `appPath` via `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` and update display name from Info.plist when empty.
  - Verification: click → new row visible + cursor blinking in bundle-ID field; type `com.apple.Safari` + Tab → display name "Safari" + icon appear.
- [x] Verify Outlook persisted correctly after user's re-add → already confirmed in `settings.v1.json`: `appPath: "/Applications/Microsoft Outlook.app"`.

#### 3d.2 — Data model: compound rules (apps ∧ hosts → action)

- [ ] **Introduce `Rule` + `HostPattern`** in `Sources/ShuntCore/Settings.swift`.
  ```swift
  public struct HostPattern: Codable, Hashable, Identifiable {
      public var id: UUID
      public enum Kind: String, Codable { case exact, suffix, cidr }
      public var kind: Kind
      public var pattern: String  // e.g. "teams.microsoft.com", "*.corp.com", "10.0.0.0/8"
  }
  public struct Rule: Codable, Identifiable, Hashable {
      public var id: UUID
      public var name: String
      public var enabled: Bool
      public var apps: [ManagedApp]      // empty = any app
      public var hosts: [HostPattern]    // empty = any host
      public enum Action: String, Codable { case route, direct }
      public var action: Action
  }
  ```
- [ ] **Evolve `ShuntSettings`**: add `rules: [Rule]` and `schemaVersion: Int = 2`. Keep `managedApps` as a legacy-decode field for v1 migration.
- [ ] **Migration v1 → v2** on decode: each `ManagedApp` becomes `Rule(name: app.displayName, enabled: app.enabled, apps: [app], hosts: [], action: .route)`. Write v2 back to disk on next save.
- [ ] **Convenience accessors** for the provider:
  ```swift
  public var activeBundleIDs: Set<String> { /* union of enabled rules' app bundle IDs, plus sentinel for rules with empty apps */ }
  public func evaluate(bundleID: String, hostname: String?, destinationIP: String?) -> Rule.Action? { /* fast path */ }
  ```

#### 3d.3 — Provider rule evaluation

- [ ] **Update `ShuntProxyProvider.handleNewFlow`** at `Sources/ShuntProxy/ShuntProxyProvider.swift:63`:
  1. For each enabled rule, AND semantics: if `rule.apps` non-empty and bundleID ∉ rule.apps → skip. If `rule.hosts` non-empty and `flow.remoteHostname` doesn't match any pattern → skip. If both pass → apply action.
  2. OR semantics across rules: first matching rule wins; default for unmatched flows is pass-through.
  3. Order rules such that "apps-only" rules (no host filter) match first (O(1) set check). Rules with host patterns pay a suffix/cidr match cost only when the bundle ID qualifies.
- [ ] **Pattern matching helpers** in `ShuntCore/HostMatcher.swift` (new): exact (case-insensitive), suffix (`*.corp.com` matches `a.b.corp.com` and `corp.com`), CIDR (parse IPv4/IPv6 + `inet_pton` + mask compare).
- [ ] **Manual smoke test**: create rule "Safari → *.github.com", open github.com in Safari → proxy IP; google.com in Safari → direct IP; teams.microsoft.com in Teams → proxy IP (separate existing rule).

#### 3d.4 — Settings window sidebar (DESIGN.md §Layout)

DESIGN.md specs `NSSplitView` sidebar 200pt + detail 620pt, window 820×520. Code has always been `TabView` 620×520. First implementation of the spec.

- [ ] **Replace TabView in `SettingsView.swift`** with `NavigationSplitView`.
- [ ] **Sidebar**: `NSVisualEffectView` material `.sidebar` via `.background(.ultraThinMaterial)` or a `NSViewRepresentable` wrapper if that doesn't render inside `NSWindowController`-hosted content.
- [ ] **Sidebar items** (6 total):
  1. General — gauge.with.needle
  2. Rules — list.bullet.rectangle (replaces Apps)
  3. Upstream — arrow.up.right
  4. Themes — paintbrush (new)
  5. Advanced — slider.horizontal.3
  6. About — info.circle
- [ ] **Sidebar row style** per DESIGN.md §Layout line 114: 14pt SF Symbol + 13pt SF Pro label, 8pt H padding, 6pt V padding. Active = amber-100 fill + amber-600 text.
- [ ] **Fallback plan**: if `NavigationSplitView` still misbehaves inside custom `NSWindowController` (the documented reason TabView was chosen), drop to AppKit-native `NSSplitViewController` with two `NSHostingController`s. Don't give up on the sidebar — DESIGN.md is authoritative.

#### 3d.5 — Themes system

Invoke `/design-consultation` to propose theme variants, then implement a picker.

- [ ] **Run `/design-consultation`** with brief: *"Propose 3 theme variants for Shunt that preserve the Precision Utility identity. Each theme: accent color, status-active color, window background (light+dark), rationale for which user would choose it. Current default is Signal Amber + PCB Green. Candidates to consider: cool-instrument (teal/cyan accent), high-contrast (monochrome + stark accent), warm-blueprint (terracotta + cream). One must stay Signal Amber as default."*
- [ ] **Theme model** in `Sources/ShuntCore/Theme.swift` (new):
  ```swift
  public struct Theme: Codable, Identifiable, Hashable {
      public var id: String
      public var name: String
      public var accentHex: String       // replaces signalAmber
      public var statusActiveHex: String // replaces pcbGreen
      public var windowBgLightHex: String
      public var windowBgDarkHex: String
  }
  public extension Theme {
      static let signalAmber: Theme = .init(id: "signal-amber", name: "Signal Amber", …)
      static let all: [Theme] = […]
  }
  ```
- [ ] **Persist selection** as `ShuntSettings.themeID: String = "signal-amber"`.
- [ ] **Apply theme globally**: swap the `Color.signalAmber`, `Color.pcbGreen` computed colors to read from the active theme via an `@Environment` value. Menu bar icon re-renders on change.
- [ ] **Themes tab UI**: vertical list of theme cards (swatch + name + rationale + radio button). Live preview card shows a mini rule row rendered in the hovered theme.

#### 3d.6 — Rules UI (replaces Apps tab)

- [ ] **`RulesTab.swift`** (new) replaces `AppsTab.swift`. Each rule row:
  - Header: editable rule name, enabled toggle, badge `"{N apps} · {M hosts} · {action}"`.
  - Expandable body: apps sub-list (current `AppRow` reused, no icon resolution logic copy — keep it in one place) + hosts sub-list (pattern TextField + kind picker: Exact / Suffix / CIDR) + action picker (Route / Direct).
- [ ] **Actions**: "Add rule", per-rule "Add app" / "Add host".
- [ ] **Validation**: a rule with both `apps=[]` and `hosts=[]` is shown with a red "Empty rule — won't match anything" inline warning; disabled from contributing to the provider's rule set until populated.
- [ ] **First-run seed**: one rule named "Managed apps" containing existing `ManagedApp` list, `hosts=[]`, `action=.route`.
- [ ] Delete `AppsTab.swift` after migration is verified.

#### 3d.7 — QA pass + doc update

- [ ] **Build + notarize + `/Applications/Shunt.app` replace + activate**.
- [ ] **Functional tests** (invoke `/qa` once UI is stable):
  - Bug fixes: Teams row shows icon; "Add by Bundle ID" scrolls + focuses.
  - Rules: create rule `Safari ∧ *.github.com → route`; verify via `curl --resolve` or by opening in Safari and inspecting egress.
  - Themes: switch between all themes; menu bar icon re-tints; settings window tint updates live.
  - Sidebar: window opens at 820×520; sidebar selection persists; keyboard nav works.
  - Migration: delete `~/Library/Group Containers/group.com.craraque.shunt/settings.v1.json` → fresh launch creates v2 with default rule; restore the old v1 JSON → launch migrates to v2 preserving Teams + Outlook + ShuntTest as one rule each.
- [ ] **DESIGN.md update**: add Themes section + Decisions Log entry for 2026-04-22 (compound rules + themes + sidebar finally implemented).
- [ ] **Commits**: one per sub-phase (3d.1 … 3d.7) for reviewability.

### Execution order

Strict sequence — each builds on the last:
1. 3d.1 bug fixes (small, commit immediately, user can dogfood)
2. 3d.2 data model + migration (no UI yet; just ShuntCore)
3. 3d.3 provider rule evaluation (headless; tested via existing ShuntTest)
4. 3d.4 sidebar redesign (visual milestone)
5. 3d.5 themes (design consultation → implementation)
6. 3d.6 rules UI (replaces Apps tab)
7. 3d.7 QA + docs

### Phase 3e — Post-ship UX fixes (from 2026-04-23 dogfooding)

- [ ] **Apply button has no visual feedback** (`Sources/Shunt/Views/UpstreamTab.swift:72-83`)
  - Clicking "Apply" saves the JSON but shows no confirmation — user perceives the button as broken.
  - Add a visual ack: transient toast ("Upstream saved"), brief checkmark on the button, or disabled-state transition ("Applied ✓" for ~1.5s then revert to "Apply"). Same pattern should apply anywhere else in Settings where a destructive/write action is taken without a modal.
  - Bonus: `apply()` currently only persists JSON; it does NOT call `proxyManager.enable()`, so the running extension keeps its old `providerConfiguration` cached. Decide: either (a) auto-trigger `proxyManager.enable()` on Apply and label the button accordingly ("Apply & Reload"), or (b) keep save-only and surface a separate "Reload extension" affordance with the caveat that live connections will briefly drop. Whichever is chosen, the visual state must make it obvious which one just happened.

- [ ] **Auto-compute `bindInterface` from upstream host IP**
  - Today the user has to know macOS bridge numbers (`bridge100` for Parallels, `bridge102` for Tart, etc.) and pick from a Picker. Numbers change between reboots and can drift when VMs are recreated.
  - Compute it from the host IP at save time (and refresh on demand) using `sysctl`/`getifaddrs` routing lookup — equivalent of `route -n get <host>` → `interface:` line. Cache the last-resolved interface and re-resolve if a dial fails.
  - UX: replace the Picker with a read-only label ("Interface (auto): bridge102") + optional "Override" expandable if the resolver ever picks the wrong NIC. Default flow: user enters IP+port, hits Apply, Shunt figures out the rest.
  - Keep the `bindInterface` field in `ShuntSettings.upstream` as an optional override, but stop requiring user input.

### Phase 3f — Upstream Launcher (generalizes VM lifecycle)

Generic "launch before connecting" orchestration. User defines one or more prerequisite commands/apps that Shunt brings up before enabling the tunnel and brings down after disabling. Tart is one concrete instance; sshuttle, `ssh -D`, Docker, any CLI-launched proxy is another. Replaces the Parallels-specific "Phase 3d — VM lifecycle" section below.

Design decisions locked (2026-04-23 conversation):
- **Lifecycle:** tied to tunnel (start on Enable Proxy, stop on Disable Proxy).
- **UI location:** expanded section inside the existing Upstream tab, below "Interface binding".
- **Ordering:** stages model (CI/CD-style). Entries within a stage run in parallel; stages run sequentially. Each stage waits for all its entries' health checks to pass before moving to the next.
- **Idempotency:** health check runs BEFORE `startCommand`. If the prereq is already healthy, do not re-start; mark as `alreadyRunning`. On Disable Proxy, only stop entries that were spawned by us — leave pre-existing processes alone.
- **Health probes:** user picks per entry from 4 options:
  1. `portOpen` — TCP connect to `upstream.host:upstream.port`.
  2. `socks5Handshake` — TCP + SOCKS5 greeting exchange.
  3. `egressCidrMatch(cidr, probeURL)` — fetch probeURL via SOCKS5, parse IP, match CIDR.
  4. `egressDiffersFromDirect(probeURL)` — fetch probeURL direct (IP A) and via SOCKS5 (IP B); pass if `A != B`. Default `probeURL` = `https://ifconfig.me/ip`.
- **Timeouts:** default `startTimeoutSeconds` = 60, `probeIntervalSeconds` = 2, both editable per entry.
- **Failure:** any entry failing its health check within timeout aborts the whole chain. Already-started entries owned by us get rolled back. Tunnel is NOT enabled. Error surfaced in `SettingsViewModel.lastError`.
- **Empirical note (reboot test 2026-04-23):** Tart guest reaches `portOpen` state within ~10s of boot, but ZCC auth completes ~35s later. `egressDiffersFromDirect` was empirically validated as the right default probe for ZCC-backed upstreams — port-only checks produce a false-positive during that ~35s window and cause Shunt to enable the tunnel while traffic still leaks to the ISP.

#### 3f.1 — Data model + migration

- [ ] **Add types to `Sources/ShuntCore/Settings.swift`:**
  ```swift
  public struct UpstreamLauncher: Codable, Hashable {
      public var stages: [UpstreamLauncherStage] = []
      public static let empty = UpstreamLauncher()
  }
  public struct UpstreamLauncherStage: Codable, Identifiable, Hashable {
      public var id: UUID
      public var name: String            // "Stage 1"
      public var entries: [UpstreamLauncherEntry] = []
  }
  public struct UpstreamLauncherEntry: Codable, Identifiable, Hashable {
      public var id: UUID
      public var name: String
      public var enabled: Bool = true
      public var startCommand: String    // run via /bin/zsh -l -c
      public var stopCommand: String?    // nil → SIGTERM tracked PID
      public var healthProbe: HealthProbe = .portOpen
      public var probeIntervalSeconds: Int = 2
      public var startTimeoutSeconds: Int = 60
  }
  public enum HealthProbe: Codable, Hashable {
      case portOpen
      case socks5Handshake
      case egressCidrMatch(cidr: String, probeURL: URL)
      case egressDiffersFromDirect(probeURL: URL)
  }
  ```
- [ ] **Add to `ShuntSettings`:** `public var launcher: UpstreamLauncher = .empty` with optional decode (absent field = `.empty`).
- [ ] **Unit tests:** decode existing v1 JSONs (no `launcher` key) → `.empty`; decode with populated launcher → round-trips.
- [ ] **No `schemaVersion` bump** — additive change, forward/back compatible at JSON level.

#### 3f.2 — Engine (headless)

- [ ] **New file `Sources/ShuntCore/UpstreamLauncherEngine.swift`.** Actor-based, all-async API.
  ```swift
  public actor UpstreamLauncherEngine {
      public func startAll(launcher: UpstreamLauncher, upstream: UpstreamProxy,
                           progress: (StageIndex, EntryID, EntryState) -> Void) async throws
      public func stopAll() async
  }
  ```
- [ ] **State machine per entry:** `.idle` → `.alreadyRunning` (probe passed before start) or `.starting(pid, since)` → `.running(pid?, ownedByUs)` / `.failed(reason)`. Stop path: `.running` → `.stopping` → `.stopped`.
- [ ] **Process spawn:** `Process` + `/bin/zsh -l -c "<startCommand>"` so user's `PATH` resolves (`tart`, `brew`-installed binaries). Capture PID. stdout/stderr → ring buffer per entry for later UI inspection.
- [ ] **Stage orchestration:** for each stage, `TaskGroup` over its entries. All entries probe health first (parallel). Those that pass → `.alreadyRunning`. Those that fail → spawn + poll every `probeIntervalSeconds` until pass or `startTimeoutSeconds` elapsed. If any entry in stage fails → cancel group, rollback previously-succeeded stages (stop our-owned entries), throw.
- [ ] **Stop flow:** reverse stage order. Within a stage, parallel stop. Only act on `.running(ownedByUs: true)`. Run `stopCommand` if set, else `SIGTERM` to tracked PID; 10s grace; `SIGKILL` if still alive.
- [ ] **Probe implementations** in `ShuntCore/LauncherProbes.swift`:
  1. `portOpen` — `NWConnection` TCP to `upstream.host:upstream.port`, 2s connect timeout.
  2. `socks5Handshake` — connect + send `0x05 0x01 0x00`, expect `0x05 0x00`, 2s timeout.
  3. `egressCidrMatch(cidr, probeURL)` — `URLSession` with SOCKS5 proxy set to upstream, fetch `probeURL`, parse IP string, CIDR match (reuse `HostMatcher` from 3d.3).
  4. `egressDiffersFromDirect(probeURL)` — one direct fetch + one SOCKS5 fetch in parallel; pass if IPs differ and both non-empty.
- [ ] **Unit tests:** mock SOCKS5 server for probe 1/2; stub URLSession for 3/4; stage orchestration test with 2 stages × 2 entries each, force one to fail, verify rollback stops the right PIDs.

#### 3f.3 — Integration into `ProxyManager`

- [ ] **`ProxyManager.enable()` gains a pre-tunnel step:**
  ```swift
  do {
      try await launcherEngine.startAll(launcher: settings.launcher,
                                        upstream: settings.upstream,
                                        progress: { stage, entry, state in
          // Publish to SettingsViewModel.launcherStatus
      })
  } catch {
      // Surface error, do NOT proceed to tunnel enable
      return
  }
  // existing: providerConfiguration + saveToPreferences + startVPNTunnel
  ```
- [ ] **`ProxyManager.disable()`** ends with `await launcherEngine.stopAll()` after `stopVPNTunnel`.
- [ ] **Empty launcher is a no-op** — existing users without prereqs see zero behavior change.
- [ ] **Error surface:** launcher failures set `settings.lastError` (string) consumed by General/Upstream tabs. UI shows red banner + "Retry" button.
- [ ] **Manual smoke:** add a launcher entry pointing to `tart run mac-zscaler-test` with `egressDiffersFromDirect` probe; toggle Disable→Enable from menu; verify tunnel comes up only after Tart's guest SOCKS5 produces a non-ISP egress.

#### 3f.4 — UI in `UpstreamTab`

- [ ] **New section below "Interface binding"**: header "Launch before connecting" + `[+ Add stage]` button.
- [ ] **Each stage renders as a collapsible GroupBox-style card**: editable name, list of entries, `[+ Add entry]` at the bottom, delete stage button (disabled if stage has entries).
- [ ] **Each entry row**: status dot + name + small badge `[running · ours]` / `[running · external]` / `[idle]` / `[failed]` / `[starting]` + `[⋯]` overflow menu.
- [ ] **Status dot colors** (pulled from active theme):
  - `idle` → neutral gray
  - `starting` → accent (amber) with pulse animation
  - `running + ours` → accent solid
  - `running + external` → theme's `statusActive` (PCB green)
  - `failed` → red
- [ ] **`[⋯]` menu per entry:** Edit, Move up, Move down, Promote to own stage, Merge with previous stage, Delete. (No drag'n'drop in v1 — deferred to v2 per design note.)
- [ ] **Entry editor sheet** (modal):
  - Name (required)
  - Start command (multiline, monospace)
  - Stop command (multiline, monospace, optional with placeholder "SIGTERM tracked PID")
  - Health probe: radio group (4 options); conditional fields per choice (CIDR text / probeURL / neither)
  - Start timeout slider/stepper (10–300s)
  - Probe interval stepper (1–30s)
  - "Enabled" toggle
- [ ] **Warning banner on first-ever entry add:** "Shunt will execute this command as your user. Only add commands you trust." Dismissable, persisted "don't show again".
- [ ] **Live status wiring:** `SettingsViewModel.launcherStatus: [StageIndex: [EntryID: EntryState]]` publishes updates from the engine's `progress` callback; UI diffs and animates dots.

#### 3f.5 — QA + docs

- [ ] **Manual test matrix:**
  - Empty launcher → tunnel behaves as today (baseline).
  - One stage, one entry (Tart + `egressDiffersFromDirect`) → enable cycle succeeds; disable stops the VM we started.
  - Two stages in sequence → stage 2 doesn't start until stage 1 is green.
  - Two entries parallel within a stage → both start at once, both health-probe independently.
  - Pre-existing running prereq (Tart already up) → entry marks `alreadyRunning`; on disable, Tart is NOT stopped.
  - Rollback: one entry in stage 2 fails → stage 1 entries we started get stopped; stage 2 untouched; error banner visible.
  - CIDR match: Zscaler entry with `cidr = "136.226.0.0/16"` → passes only after ZCC auth completes.
- [ ] **`docs/upstream-launcher.md`:** concept explainer + three worked examples (Tart, `ssh -D 1080`, `sshuttle`). Include the empirical ZCC-auth-window note.
- [ ] **DESIGN.md Decisions Log** entry dated 2026-04-23: "Upstream launcher feature added; stages model chosen over flat ordered list to express mix of parallel + sequential; `egressDiffersFromDirect` default probe validated against ZCC auth window."
- [ ] **Memory close-out:** update `project_shunt_upstream_launcher.md` status from "design pending" to "shipped in v0.3" (when merged).

### Execution order

Strict sequence, one commit per sub-phase:
1. 3f.1 data model (smallest, no runtime risk)
2. 3f.2 engine (headless, unit-testable)
3. 3f.3 integration (minimal surface change in ProxyManager)
4. 3f.4 UI (largest chunk; land last so the feature becomes user-accessible in one PR)
5. 3f.5 QA + docs

Rough effort estimate: 3f.1 ~2h, 3f.2 ~4h, 3f.3 ~2h, 3f.4 ~6h, 3f.5 ~2h. ~16h total, 5 commits.

### Phase 3d — VM lifecycle (SUPERSEDED by 3f)

The Parallels-specific auto-start idea below is subsumed by Phase 3f. Keeping here only to preserve original intent for the Decisions Log; will be deleted once 3f.5 ships.

- [ ] ~~Detectar estado de la VM Parallels (`prlctl list`)~~
- [ ] ~~Auto-start si está apagada~~
- [ ] ~~Health check: TCP reachability a `10.211.55.5:1080`~~
- [ ] ~~UI en VM tab mostrando estado~~

## Phase 4 — macOS guest migration

- [ ] Confirm Zscaler licensing allows macOS guest enrollment (user with IT/Zscaler)
- [ ] Provision macOS guest via VirtualBuddy or Tart; install Zscaler; install 3proxy (or equivalent)
- [ ] Compare RAM/CPU vs Windows VM
- [ ] Shunt VM control: shell out to Tart CLI initially; later, embed `Virtualization.framework` if worth the effort

## Phase 5 — Ship

- [ ] Entitlement approved → build with real profile
- [ ] Notarization pipeline (`Scripts/release.sh` per RESEARCH.md §4.6)
- [ ] Smoke test install on a clean Mac

## Open decisions (from RESEARCH.md §7.2)

- Corporate apps list beyond Teams/Outlook
- VM-down behavior (auto-start recommended)
- Per-app bandwidth UI or ephemeral only
- Remote DNS via SOCKS vs local DNS

## Phase 6 — Toggle in-flight feedback + cancellation UX (planning, NOT for now)

**Reported 2026-04-28.** When the user clicks Enable in the menubar popover with a launcher entry that takes seconds-to-tens-of-seconds to come up (Parallels/Tart resume, then Zscaler reauth, then probe pass), the toggle flips visually but offers zero feedback about what's happening. The header still says "Routing engine"; the toggle has no spinner; the user can re-click and trigger an unsafe mid-flight disable.

### Goals

1. Show *something is happening* in the same surface the user just clicked (popover header).
2. Show *what specifically* is happening — which entry, which stage, what state.
3. If the user clicks the toggle again mid-operation, surface a confirmation with a sensible default rather than silently issuing a competing command.

### State the engine already exposes (we just don't render it)

- `ProxyActivity.shared.busy` — `true` while launcher is running (start or stop) OR tunnel is in NEVPNStatus 2 (connecting), 4 (reasserting), 5 (disconnecting). Already published, already observed by `AppDelegate` for the menubar pulse.
- `ProxyActivity.shared.entries[uuid]` — per-entry `EntryProgress { state, ownedByUs, detail, ... }`. Drives the "N/M ready" pill in the Upstream tab. State enum: `idle / starting / running / failed / stopping / stopped`.
- `UpstreamLauncherEngine.inFlightStartTask` — `Task` handle for the active startAll. Already cancellable via `stopAll`, which cancels then runs teardown of stages we own.
- `NEVPNStatus` from `proxyManager.statusRaw()` — separate signal layer, polled every 3s by `AppDelegate.refreshStatus`.

### 6a. Toggle becomes a state-aware button (not just an `isOn` mirror)

- [ ] **Replace the popover header `Toggle` with a custom morphing button** whose visual reads three states:
  - `idle` (off): standard switch, off position, off-tint.
  - `idle` (on): standard switch, on position, accent-tint, header subtitle "Live routing".
  - `working`: switch knob replaced by a small `ProgressView`, base capsule pulses at the active accent. Subtitle shows the live status string (see 6b).
- [ ] **Bind `working` to** `ProxyActivity.busy || statusRaw == 2 || statusRaw == 4 || statusRaw == 5`. Same predicate as the existing menubar pulse so the two indicators are coherent.
- [ ] **Disable second-click of the toggle while in `working`** — but route the click to the cancel-confirmation flow (6c), not to a no-op.

### 6b. Live status string in the popover subtitle

Use the most-specific signal available. Priority, top-down:

1. **Launcher running** → `"Starting <entryName>…"` (e.g. "Starting macOS guest (Zscaler)…"). Pulled from the latest `EntryProgress` whose state is `.starting`.
2. **Launcher health-probing** → `"Waiting for <entryName>…"` once entry is `.starting` and probe attempts > 1. (Engine doesn't expose probe-attempt count today; either extend `Event.detail` to include it, or fold this into 1 with a 5 s threshold.)
3. **Launcher tearing down** → `"Stopping <entryName>…"` for `.stopping`.
4. **NE tunnel connecting** → `"Connecting tunnel…"` when `statusRaw == 2` and no launcher is in flight.
5. **NE tunnel disconnecting** → `"Disconnecting tunnel…"` when `statusRaw == 5`.
6. **NE tunnel reasserting** → `"Reconnecting tunnel…"` when `statusRaw == 4`.
7. Default (idle): existing strings (`"Live routing"` or `"Routing engine"`).

- [ ] Add `MenubarPopoverModel.workingDescription: String?` populated by `AppDelegate.refreshStatus()` from `ProxyActivity.shared.entries` + `statusRaw`.
- [ ] Render in the existing subtitle slot when non-nil; fall back to `model.isRouting ? "Live routing" : "Routing engine"` otherwise.

### 6c. Cancel-confirmation when user re-clicks during work

When the user clicks the toggle while `ProxyActivity.busy == true`, present a modal alert with three options:

- [ ] **NSAlert "Shunt is bringing the tunnel up"** with the live status as informative text:
  - **Cancel and tear down** (destructive style): calls `proxyManager.disable()` immediately. The launcher's `stopAll` cancels `inFlightStartTask`, kills any spawned PIDs we own, and runs `stopCommand` for entries the user authored one for. Tunnel never reaches `connected`.
  - **Wait for it to finish, then disable** (default): set a `MainQueue` flag `pendingDisableAfterEnable = true`. AppDelegate observes `statusRaw` transitions and, on the first time it sees `connected`, fires a delayed `proxyManager.disable()`. Surface a small "queued disable" indicator in the header so the user knows.
  - **Keep enabling** (safe cancel): dismiss alert, no-op.
- [ ] Mirror the same logic in reverse for **Disable mid-flight**: if the user clicks toggle ON while `statusRaw == 5` or stopAll is in flight, offer "Cancel disable / Wait then re-enable / Keep disabling".

Implementation notes:
- The alert lives in `AppDelegate` (already where similar prompts live, e.g. the new external-reclaim ask-prompt).
- `pendingDisableAfterEnable` is in-memory state on AppDelegate; lost on app quit. That's fine — the user is right there.
- The "Wait for it to finish" path needs a watchdog: if status stays in `.connecting` past 60 s, abandon the queued disable and surface a failure toast (don't leave the user wondering forever).

### 6d. Engine work to expose better signals

Optional, only if 6b's "5 s threshold" feels lazy:

- [ ] Extend `UpstreamLauncherEngine.Event.detail` (or add a new `Event.kind` enum value) so probe attempts publish a structured `attempt: Int, deadline: Date` instead of a free-form string. Lets the UI render an accurate ETA / progress bar without parsing text.
- [ ] Surface `inFlightStartTask` state via a public `engine.inFlight: Bool` so the UI doesn't have to derive it from `ProxyActivity.busy` (the two are equivalent today; making it explicit helps when adding more orchestration).

### Risks / gotchas

- **Quick double-click race.** Today, double-clicking the toggle within ~150 ms enqueues two NE state changes. The state-aware button must debounce *visually* on the first click (immediate spinner) but *functionally* still serialize on the actor — both `proxyManager.enable()` and `disable()` already serialize via NEVPNManager's KVO, but the user should never see two competing prompts.
- **Sysext not yet activated.** When `model.extensionInstalled == false`, today the toggle is `.disabled(true)`. Keep this exact behavior — the working-state UI only kicks in once the sysext exists. (Activation has its own tab flow.)
- **VPN reauth window with autorenewal.** If the user toggles ON and Zscaler is mid-reauth in the VM, the egress probe can pass *intermittently*. Don't flap the working indicator — once `.starting` for an entry, hold the indicator until either `.running` or `.failed`. Probe re-tries don't change the visible state.
- **Ergonomics of the alert.** Three buttons is the upper limit; don't add a fourth. If we ever add "queue cancel, but also reset launcher to idle" or similar, fold it into a kebab menu next to the alert.

### Effort estimate

- 6a + 6b: ~150 LOC, 1 popover file change + small `MenubarPopoverModel` additions. ~1.5 h.
- 6c: ~80 LOC in `AppDelegate` + 1 alert, ~1 h.
- 6d: ~30 LOC, optional, ~30 min.

Total: 2.5–3 h, no sysext cycle (UI only — main app rebuild only).
