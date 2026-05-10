# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Shunt** is a native macOS menu-bar app that transparently routes network traffic from a user-configurable list of apps (default: Microsoft Teams, Outlook) through a VM running Zscaler Client Connector, while all other host traffic uses the host's direct internet connection.

**Context:** Personal BYOD Mac on Apple Silicon. Zscaler is installed only for corporate resources. The goal is isolating Zscaler from the host OS — not disabling or evading it. Successor to [`~/dev/zOFF`](../zOFF) (toggle-based), which used a simpler kill-apps + unload-launchd approach.

Before doing any architectural work, read `docs/RESEARCH.md` — it is the source of truth for interception mechanism, hypervisor choice, and Apple approval strategy.

## Architecture (decided in research)

- **Host-side interception:** `NETransparentProxyProvider` packaged as a **System Extension** (not an in-process Network Extension). Claims only flows whose `NEAppProxyFlow.metaData.sourceAppSigningIdentifier` matches the managed bundle list; all other flows pass through untouched.
- **Transport host → VM:** SOCKS5 (TCP + UDP ASSOCIATE) over a local loopback port forwarded from the guest.
- **VM:** Zscaler Client Connector runs inside the guest. **PoC** uses the user's existing Windows 11 ARM VM with Zscaler already installed. **Production target:** macOS guest on Apple Virtualization Framework (native arm64, Swift-controllable via `Virtualization.framework`, ~3-4 GB idle). **Fallback** if Zscaler licensing blocks macOS guest: Parallels + Windows 11 ARM (user has a Parallels license).
- **Distribution:** Developer ID + notarization, **not** App Store. Avoids editorial review; notarization is automated.

## Tech stack

- Swift 6+, macOS 14+ (Sonoma), Apple Silicon (arm64) only.
- SwiftUI for settings window; AppKit (`NSStatusItem`) for menu bar.
- `@Observable` (Observation framework) for state.
- Swift concurrency (`async/await`) everywhere; wrap `NEAppProxyFlow` callback APIs with `withCheckedContinuation`.
- Swift Package Manager, no `.xcodeproj`, no third-party dependencies.
- Two SwiftPM targets minimum: main app (`Shunt`) and system extension (`ShuntProxy`).

## Entitlements / Network Extension packaging

Required entitlement keys for Developer ID distribution:
- Container app: `com.apple.developer.system-extension.install`
- System extension / proxy entitlement: `com.apple.developer.networking.networkextension` with value `app-proxy-provider-systemextension`

Important Apple quirk: Shunt implements `NETransparentProxyProvider`, but for Developer ID system-extension distribution it still uses the app-proxy entitlement family and the `Info.plist` `NEProviderClasses` key `com.apple.networkextension.app-proxy`. Do **not** use the folklore value `transparent-proxy-systemextension` or the plist key `com.apple.networkextension.transparent-proxy`; current tests assert this packaging contract.

For local development:

```bash
systemextensionsctl developer on
# reboot required
```

This allows loading ad-hoc-signed System Extensions for development only. Turn off before shipping.

## Build

Follow the zOFF pattern once the project scaffold exists:

```bash
swift build -c release --arch arm64
# a build.sh (to be written) will produce the .app bundle and embed the system extension
```

System extension must be embedded at `Contents/Library/SystemExtensions/` inside the main `.app`. The main app activates it via `OSSystemExtensionRequest`.

## Conventions

- No hardcoded paths — everything configurable via Settings.
- No analytics, telemetry, or network calls unrelated to the managed-app routing.
- All user-facing strings localizable (String Catalog): English + Spanish.
- LSUIElement = true (menu bar only, no Dock icon).
- Bundle ID: `com.craraque.shunt`. System extension bundle ID: `com.craraque.shunt.proxy`.
- "Made by Cesar Araque". No other branding.

## UI pattern (inherited from zOFF)

- Menu bar icon via SF Symbols, monochrome, respects light/dark.
- Global hotkey (configurable, default unassigned — Shunt is not a toggle).
- Settings window (⌘,) with tabs: **General, Apps, VM, Advanced, About**.
- Apps tab: list of managed apps (bundle ID + display name + icon), add/edit/remove, per-app on/off toggle.
- Persist via `UserDefaults` suite `com.craraque.shunt`. Export/import as JSON.

## Workflow files

- `tasks/todo.md` — live plan.
- `tasks/lessons.md` — corrections from the user (create on first correction).
- `docs/RESEARCH.md` — research and architecture source of truth. Read before architectural changes.
- `DESIGN.md` — design system source of truth. Read before any UI/visual change.

## Design System

Always read `DESIGN.md` before making any visual or UI decision. All font choices, colors, spacing, iconography, and aesthetic direction are defined there. Do not deviate without explicit user approval. When reviewing code, flag anything that doesn't match `DESIGN.md`.

Quick reference:
- **Aesthetic:** Precision Utility — electrical schematic meets macOS HIG.
- **Fonts:** SF Pro (UI), SF Mono with tabular-nums (network data: IPs, ports, bundle IDs).
- **Colors:** Signal Amber `#E8860F` (brand), PCB Green `#22C55E` (routing-active only), system neutrals.
- **No gradients in UI** (icon background excepted).
- **No custom animations in v0.1** — system transitions only.
