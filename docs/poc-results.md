# PoC Results — Phase 2

**Date:** 2026-04-20
**Goal:** Validate end-to-end that host traffic can be forced through a SOCKS5 endpoint inside a VM running Zscaler and egress via Zscaler (not the host ISP).

## Setup

- **Host:** macOS (Mac M2 Max), local ISP egress IP `71.229.98.157`
- **Hypervisor:** Parallels Desktop
- **Guest:** Windows 11 ARM, VM IP `10.211.55.5` on Parallels shared network (NAT, `10.211.55.0/24`)
- **Proxy:** 3proxy 0.9.6 ARM64, listening on `0.0.0.0:1080` inside guest
- **VPN client:** Zscaler Client Connector installed inside the guest, Zscaler egress IP observed: `165.225.223.34`
- **3proxy config:** minimal — `auth none`, `allow *`, `socks -p1080 -i0.0.0.0` (see `poc/3proxy-minimal.cfg`)

No Parallels port-forward was needed — the host routes to `10.211.55.0/24` natively in shared mode, so the guest is directly reachable at `10.211.55.5:1080`.

## Egress segregation test

```
$ curl -s https://ifconfig.me                                        # direct
71.229.98.157
$ curl -s --socks5-hostname 10.211.55.5:1080 https://ifconfig.me     # via VM
165.225.223.34
```

**Result:** Traffic is fully segregable at the `curl` level. ✅

## Real-endpoint test (Microsoft Graph)

Five iterations against `https://graph.microsoft.com/v1.0/$metadata`, HTTP 200 in all cases.

| Path     | Mean total | Mean TLS | Variability             |
|----------|-----------:|---------:|-------------------------|
| Direct   | ~190 ms    | ~143 ms  | Stable (±7 ms)          |
| Via proxy| ~453 ms    | ~310 ms  | One outlier at 1.5 s    |

**Overhead:** ~263 ms per fresh TLS connection (host → VM → Zscaler cloud → Microsoft). Amortized over the life of a session; streaming (Teams voice, Outlook sync) does not pay this per-packet.

One outlier at 1.5 s on the proxy path suggests jitter from either (a) 3proxy scheduling inside the Windows VM, (b) Zscaler client buffer handoff, or (c) Parallels NAT overhead. Not investigated further — out of scope for "does it work" PoC.

## Findings

1. **Architecture validated.** The core Shunt hypothesis — host app traffic re-routed through a VM-resident VPN and indistinguishable from native Zscaler traffic — works as designed.
2. **Host-to-guest reachability is free in shared mode.** No `prlsrvctl` port-forward required. For production Shunt, the System Extension provider can target `10.211.55.5:1080` directly, or we can add a host-local port-forward later if we prefer the `127.0.0.1:1080` ergonomics.
3. **Latency overhead is acceptable.** ~260 ms per TLS connect is noticeable on cold starts but invisible on sustained flows. Teams/Outlook primarily use long-lived HTTP/2 + WebSocket connections, so the overhead is paid once.
4. **DNS works through SOCKS5.** We use `--socks5-hostname` (remote DNS). The name is resolved inside the VM, so the host never leaks DNS for proxied apps. This is the behavior Shunt needs by default.

## Decisions for next phase

- **Proxy address in Shunt provider:** start with VM IP directly (`10.211.55.5:1080`). Reconsider if we ship generic Parallels support vs requiring the user to configure.
- **Production proxy:** 3proxy is fine for PoC but may not be the long-term choice. For the macOS guest target, we'll want a proxy that runs cleanly as a launchd service and is trivially scriptable. Candidates: `microsocks`, `ssh -D` (no UDP), or continue with 3proxy.
- **UDP ASSOCIATE not yet tested.** Current config enables SOCKS5 TCP; UDP support in 3proxy is on by default but needs a real UDP flow to verify. Defer until we have a Teams call test.

## Open items from Phase 2

- [ ] UDP ASSOCIATE verification with a real Teams call (requires Shunt provider to actually claim the Teams process)
- [ ] Re-test latency with longer-lived connections (keep-alive, HTTP/2 multiplexing) to confirm overhead is one-time
- [ ] Try the same PoC with the macOS guest (Phase 4) to see if VM-level overhead changes
