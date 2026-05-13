# Contributing

Shunt is a native macOS utility for per-application routing through user-defined SOCKS5 upstreams.

## Development

```bash
swift test --package-path .
swift build -c release --arch arm64 --product Shunt --package-path .
swift build -c release --arch arm64 --product ShuntProxy --package-path .
```

Developer ID packaging and notarization require local Apple developer certificates, provisioning profiles, and notary credentials. Those assets are not part of this repository.

## Code Guidelines

- Keep configuration local-first.
- Do not add analytics or telemetry.
- Prefer generic examples: `Example`, `*.example.com`, `proxy-vm`, `127.0.0.1:1080`.
- Read `DESIGN.md` before UI changes.
- Use `docs/architecture.md` for the high-level architecture contract.

## Network Extension Notes

Developer ID builds use:

- Container app entitlement: `com.apple.developer.system-extension.install`.
- System extension entitlement family: `app-proxy-provider-systemextension`.
- System extension `Info.plist` provider class: `com.apple.networkextension.app-proxy`.

The provider implementation may use transparent/app proxy APIs, but packaging must match the entitlement and plist values asserted by tests.
