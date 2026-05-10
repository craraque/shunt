# Reverse SSH tunnel upstream

Use this profile when the SOCKS5 proxy runs in a VM/container/remote environment and Shunt should consume it locally as `127.0.0.1:<host-port>`.

Tart is **not** a production requirement. Tart is only the development wrapper used by the current test VM. Production can use Parallels, VMware, a plain remote host, launchd, or an externally managed tunnel.

## Contract Shunt needs

Shunt only needs this to be true before the Network Extension starts:

- A SOCKS5 endpoint is reachable from the host at `127.0.0.1:<host-port>`.
- The SOCKS5 server supports CONNECT and, ideally, domain-name CONNECT (`ATYP=0x03`) for remote DNS.
- If the goal is egress shift, a probe through SOCKS returns a different public IP than direct host egress, or matches a configured CIDR.
- If Shunt owns startup, the launcher command stays in the foreground so Shunt can stop the tracked PID on disable.

## Recommended topology

```text
macOS host / Shunt
  upstream = 127.0.0.1:1080
          ↑
          │ ssh -R 127.0.0.1:1080:127.0.0.1:1080
          │
VM / container / remote environment
  SOCKS5 = 127.0.0.1:1080
  VPN/Zscaler/Surfshark/etc owns egress
```

The important part is the direction: the VM/remote side opens SSH **back to the host**, and the host receives a loopback listener via `ssh -R`.

## SSH key requirements

For `ssh -R`, the SSH client runs in the VM/remote environment and connects to the host.

Required setup:

1. Host has SSH server enabled and reachable from the VM/remote environment.
2. VM/remote environment has the **private key** used by the SSH client.
3. Host user's `~/.ssh/authorized_keys` contains the matching **public key**.
4. Host `sshd` allows remote forwarding:
   - `AllowTcpForwarding remote` or `yes`
   - optional hardening with `PermitListen 127.0.0.1:1080`
5. The reverse listener should bind to host loopback only:
   - `-R 127.0.0.1:1080:127.0.0.1:1080`

Important distinction:

- `permitlisten` / `PermitListen` controls `ssh -R` destinations/listeners.
- `permitopen` controls `ssh -L`; it does **not** secure this reverse-forward path.

Example `authorized_keys` hardening on the host:

```text
restrict,port-forwarding,permitlisten="127.0.0.1:1080" ssh-ed25519 AAAA... shunt-tunnel
```

## Generic launcher command

When the command is executed from inside the VM/remote environment:

```bash
ssh -N \
  -R 127.0.0.1:1080:127.0.0.1:1080 \
  -o IdentitiesOnly=yes \
  -i /path/inside/remote/to/id_shunttunnel \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes \
  -o StrictHostKeyChecking=accept-new \
  admin@<host-ip-visible-from-remote>
```

For a VM wrapper, prepend the command that executes inside the VM.

Tart development example:

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

Parallels shape, adjust VM name/path/IP:

```bash
prlctl exec "<vm-name>" ssh -N \
  -R 127.0.0.1:1080:127.0.0.1:1080 \
  -o IdentitiesOnly=yes \
  -i /path/inside/vm/id_shunttunnel \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes \
  -o StrictHostKeyChecking=accept-new \
  admin@<host-ip-visible-from-vm>
```

## Shunt upstream settings

- Host: `127.0.0.1`
- Port: host reverse-listener port, usually `1080`
- Bind interface: empty / none
- Remote DNS: ON
- Auth: OFF unless the SOCKS5 server itself requires username/password

## Shunt launcher settings

- Stage name: `SSH reverse tunnel`
- Entry name: `Host localhost:<host-port> ⇠ remote SOCKS:<remote-port>`
- Start command: editable `ssh -R` command or VM-wrapper command
- Stop command: empty if the start command stays foreground; Shunt SIGTERMs the tracked process
- Health probe: `egressDiffersFromDirect(https://ifconfig.me/ip)` for egress-shift VPNs, or `egressCidrMatch` for known corporate ranges
- Timeout: `90s`
- Probe interval: `2s`
- External policy: `neverReclaim` when another process may own the tunnel

## Manual validation

```bash
# Is the host loopback listener up?
lsof -nP -iTCP:1080 -sTCP:LISTEN

# Direct host egress
curl -4fsS --max-time 15 https://api.ipify.org

# SOCKS egress with remote DNS
curl -4fsS --max-time 20 --socks5-hostname 127.0.0.1:1080 https://api.ipify.org

# Extra trace signal
curl -4fsS --max-time 20 --socks5-hostname 127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace
```

Expected for egress-shift setups: direct IP and proxied IP differ.

Validated development topology on 2026-05-10:

- Host direct: `71.229.98.157`
- Host via reverse SOCKS: `89.117.41.116`
- Remote-DNS SOCKS curl passed against `ifconfig.me`, `api.ipify.org`, and Cloudflare trace.

## Helper script

`Scripts/tart-reverse-tunnel.sh` remains a development helper for the current Tart VM. It is not required for production and should not be referenced by installed app settings because an installed app may not live inside the source checkout.
