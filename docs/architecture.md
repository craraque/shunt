# Architecture

Shunt consists of a SwiftUI/AppKit menu-bar app and a Network Extension System Extension.

The app stores user rules and upstream settings, activates the System Extension, and exposes status through a menu-bar UI and settings window. The extension receives eligible flows and forwards routed TCP traffic to the configured SOCKS5 upstream.

Typical upstreams include:

- a local SOCKS5 proxy,
- a proxy running in a VM or container,
- an SSH dynamic or reverse tunnel,
- another user-managed service.

The launch-before-connect system can start dependencies before enabling the tunnel and stop them after disabling it. Health probes verify that an upstream is ready before routing begins.
