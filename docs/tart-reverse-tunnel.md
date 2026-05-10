# Tart reverse tunnel upstream

Use this profile when the SOCKS5 proxy lives inside a Tart macOS guest and the guest VPN/Surfshark/Zscaler may break direct host → guest connectivity.

## Validated topology

- VM: `tahoe-base`
- Host bridge IP visible from VM: `192.168.64.1`
- Guest SOCKS: `127.0.0.1:1080` inside the VM (`3proxy_socks`)
- Host Shunt upstream: `127.0.0.1:1080`
- Probe: direct host egress must differ from SOCKS egress

## Start command for Shunt launcher

The UI preset stores the raw command so it continues to work after the app is installed outside the source checkout:

```bash
tart exec tahoe-base ssh -N \
  -R 127.0.0.1:1080:127.0.0.1:1080 \
  -o IdentitiesOnly=yes \
  -i /Users/admin/.ssh/id_shunttunnel \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes \
  -o StrictHostKeyChecking=accept-new \
  admin@192.168.64.1
```

The helper script is for manual validation and ad-hoc runs from the source checkout:

```bash
Scripts/tart-reverse-tunnel.sh start tahoe-base 192.168.64.1 1080 1080
```

## Shunt upstream settings

- Host: `127.0.0.1`
- Port: `1080`
- Bind interface: empty / none
- Remote DNS: ON
- Auth: OFF

## Launcher entry

- Name: `tahoe-base → localhost:1080`
- Start command: raw `tart exec tahoe-base ssh -N -R 127.0.0.1:1080:127.0.0.1:1080 ... admin@192.168.64.1` command
- Stop command: empty (Shunt SIGTERMs the tracked foreground process)
- Health probe: `egressDiffersFromDirect(https://ifconfig.me/ip)`
- Timeout: `90s`
- Probe interval: `2s`
- External policy: `neverReclaim`

## Manual validation

```bash
# Host
Scripts/tart-reverse-tunnel.sh test tahoe-base 192.168.64.1 1080 1080

# Expected shape:
# direct=71.229.98.157
# proxied=<Surfshark/Zscaler/guest VPN IP>
```

Validated on 2026-05-10 with Surfshark in the VM:

- Host direct: `71.229.98.157`
- Host via reverse SOCKS: `89.117.41.116`

## Code hook

`ShuntCore.TartReverseTunnelPreset` builds the matching `UpstreamProxy` and `UpstreamLauncher` objects for future UI/CLI preset wiring. It keeps the important SSH flags (`IdentitiesOnly`, `ExitOnForwardFailure`, `StrictHostKeyChecking=accept-new`, keepalives) and shell-quotes user-provided fields.
