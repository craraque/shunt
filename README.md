# Shunt

Shunt is a native macOS menu-bar app for routing selected applications through a user-defined upstream SOCKS5 proxy while leaving other traffic on the default network.

It is designed for local-first per-app network segmentation: choose apps, optionally add hostname rules, configure an upstream, and let Shunt handle the Network Extension plumbing.

## Status

Early macOS Network Extension project. Developer ID signing and notarization require local Apple developer assets that are not included in this repository.

## Features

- Per-application routing rules.
- Optional hostname/domain matching.
- Configurable SOCKS5 upstream.
- Optional interface binding for upstreams reachable through non-default interfaces.
- Launch-before-connect orchestration for VMs, SSH tunnels, containers, or custom commands.
- Local configuration, no analytics.

## Development

```bash
swift test --package-path .
swift build -c release --arch arm64 --product Shunt --package-path .
swift build -c release --arch arm64 --product ShuntProxy --package-path .
```

Packaging a signed `.app` and notarized `.dmg` requires your own Developer ID certificate, provisioning profiles, and notary credentials.

## Security / Responsible Use

Shunt is a routing and segmentation utility. Use it only on systems and networks where you are authorized to configure routing behavior.
