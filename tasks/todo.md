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

### Phase 3d — VM lifecycle

- [ ] Detectar estado de la VM Parallels (`prlctl list`)
- [ ] Auto-start si está apagada
- [ ] Health check: TCP reachability a `10.211.55.5:1080`
- [ ] UI en VM tab mostrando estado

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
