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

### Phase 3c — Settings window

- [ ] Apps tab funcional (add/edit/remove bundle IDs)
- [ ] Persistencia via UserDefaults suite com.craraque.shunt
- [ ] Export/import JSON
- [ ] Config compartida entre main app y extension vía App Group (`group.com.craraque.shunt`)

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
