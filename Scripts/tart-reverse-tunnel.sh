#!/usr/bin/env bash
set -euo pipefail

# Start or validate a Tart guest → host loopback SOCKS reverse tunnel.
# Intended Shunt launcher command:
#   Scripts/tart-reverse-tunnel.sh start tahoe-base 192.168.64.1 1080 1080
#
# The start action stays in the foreground and execs ssh; Shunt's launcher owns
# that PID and can stop it with SIGTERM.

action="${1:-status}"
vm_name="${2:-tahoe-base}"
host_ip="${3:-192.168.64.1}"
host_port="${4:-1080}"
guest_port="${5:-1080}"
ssh_user="${SHUNT_TUNNEL_USER:-admin}"
identity="${SHUNT_TUNNEL_IDENTITY:-~/.ssh/id_shunt_tunnel}"
probe_url="${SHUNT_PROBE_URL:-https://ifconfig.me/ip}"

case "$action" in
  print-command)
    printf 'tart exec %q ssh -N -R 127.0.0.1:%q:127.0.0.1:%q -o IdentitiesOnly=yes -i %q -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new %q@%q\n' \
      "$vm_name" "$host_port" "$guest_port" "$identity" "$ssh_user" "$host_ip"
    ;;
  start)
    exec tart exec "$vm_name" ssh -N \
      -R "127.0.0.1:${host_port}:127.0.0.1:${guest_port}" \
      -o IdentitiesOnly=yes \
      -i "$identity" \
      -o ServerAliveInterval=15 \
      -o ServerAliveCountMax=3 \
      -o ExitOnForwardFailure=yes \
      -o StrictHostKeyChecking=accept-new \
      "${ssh_user}@${host_ip}"
    ;;
  status)
    lsof -nP -iTCP:"$host_port" -sTCP:LISTEN || true
    ;;
  test)
    direct="$(curl -4fsS --max-time 15 "$probe_url" || true)"
    proxied="$(curl -4fsS --max-time 20 --socks5-hostname "127.0.0.1:${host_port}" "$probe_url" || true)"
    printf 'direct=%s\nproxied=%s\n' "$direct" "$proxied"
    if [[ -n "$direct" && -n "$proxied" && "$direct" != "$proxied" ]]; then
      exit 0
    fi
    exit 1
    ;;
  *)
    echo "usage: $0 {start|status|test|print-command} [vm-name] [host-ip] [host-port] [guest-port]" >&2
    exit 64
    ;;
esac
