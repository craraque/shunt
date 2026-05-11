# Shunt — Claude Code Guide

This file is safe for the public repository. Keep private deployment notes, customer-specific context, and local experiments in `.claude/CLAUDE.local.md` or another gitignored local file.

## Project

Shunt is a native macOS menu-bar app for per-application network routing. It lets users route selected app traffic through a user-defined upstream SOCKS5 proxy, VM, tunnel, or remote service while leaving other traffic on the default network.

## Architecture

- Swift / SwiftUI menu-bar app with AppKit `NSStatusItem`.
- Network Extension System Extension for per-app flow handling.
- Rules combine applications and optional hostname patterns.
- Configurable upstream SOCKS5 endpoint.
- Optional launch-before-connect orchestration for VMs, SSH tunnels, containers, or other local dependencies.
- Local-first configuration; no analytics or telemetry.

## Entitlements / Network Extension Packaging

Developer ID builds use:

- Container app entitlement: `com.apple.developer.system-extension.install`.
- System extension entitlement family: `app-proxy-provider-systemextension`.
- System extension `Info.plist` provider class: `com.apple.networkextension.app-proxy`.

The provider implementation may subclass transparent/app proxy APIs, but Developer ID packaging must match the entitlement and plist values asserted by the tests. Do not use folklore values unless Apple provisioning profiles and tests are updated accordingly.

## Development Commands

```bash
swift test --package-path .
swift build -c release --arch arm64 --product Shunt --package-path .
swift build -c release --arch arm64 --product ShuntProxy --package-path .
```

Developer ID packaging/notarization requires local provisioning profiles and signing identities that are intentionally not included in the public repository.

## Public Framing

Describe Shunt as:

- per-app routing
- user-defined upstreams
- network segmentation
- local-first configuration

Avoid adversarial security-control framing. Present Shunt as a user-controlled routing and segmentation utility.

## Design

Read `DESIGN.md` before UI changes. Keep UI examples generic (`Example`, `*.example.com`, `proxy-vm`) and avoid embedding personal, customer, or provider-specific setup details.
