# Shunt Local Proxy Validation Plan

> Implementation note: execute this plan task-by-task and verify each phase before continuing.

**Goal:** Validate whether Shunt can correctly route only selected macOS app traffic through a local test proxy, without using upstream provider.

**Architecture:** Use a local SOCKS5 test upstream on the Mac or a lightweight local VM/container, then configure Shunt to route a controlled test app through it. Validate routing by comparing direct vs proxied egress, inspecting SOCKS logs, and confirming non-managed apps remain direct.

**Tech Stack:** Swift/macOS Network Extension, Shunt app/system extension, SOCKS5 proxy, Python/Go/3proxy/Microsocks, local HTTP echo endpoints, macOS `log stream`, `curl`, packet/log verification.

---

## Scope

This plan is for **validation**, not production hardening. It deliberately avoids upstream provider so we can isolate Shunt behavior from user-defined upstream/client behavior.

## Locality / Git Safety

- Any code changes stay local in `/path/to/shunt` unless explicitly pushed.
- I will not push, tag, release, notarize, or install over `/Applications/Shunt.app` without explicit instruction.
- Recommended workflow: create a local branch, make fixes/tests there, then show diff.

```bash
cd /path/to/shunt
git checkout -b validation/local-proxy-shunt
```

---

## Validation Questions

We need to prove these claims:

1. **Selective routing:** A managed app's TCP traffic is claimed by Shunt.
2. **Non-managed passthrough:** Other apps remain on the normal host path.
3. **Rule correctness:** Bundle ID and host rules match only what they should.
4. **SOCKS correctness:** Shunt sends valid SOCKS5 CONNECT requests.
5. **Remote DNS behavior:** With `useRemoteDNS=true`, hostname CONNECT uses ATYP domain, not host-resolved IP.
6. **Failure behavior:** If the proxy is down, Shunt fails gracefully and does not wedge the system.
7. **Privacy posture:** Logs are sufficient for testing but do not accidentally expose secrets.

---

## Test Environments

### Environment A — Local SOCKS5 on the Mac via 3proxy

Use this first. Lowest moving parts.

`3proxy` is the preferred local SOCKS5 harness for this scenario.

Preferred:

```bash
brew install 3proxy
cd /path/to/shunt
3proxy poc/3proxy-minimal.cfg
```

If the config needs to be adjusted, use a minimal loopback-only SOCKS config:

```cfg
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /tmp/shunt-3proxy.log D
logformat "L%Y-%m-%d %H:%M:%S %N.%p %E %U %C:%c -> %R:%r %O %I"
auth none
allow * 127.0.0.1
socks -p1080 -i127.0.0.1 -e127.0.0.1
```

Pros:
- Known-good for local SOCKS5 validation.
- Fast setup.
- Easy to observe logs.
- Good for validating Shunt's SOCKS5 behavior.

Cons:
- Egress IP may be the same as direct host egress, so egress-diff tests may not prove much.

### Environment B — Local container/VM proxy with different egress path

Use after Environment A passes.

Possible choices:
- Tiny Linux VM via UTM/Parallels/Tart.
- Docker container running SOCKS5 proxy, if Docker networking exposes a host-reachable IP/port.
- SSH dynamic SOCKS to a remote VPS:

```bash
ssh -N -D 127.0.0.1:1080 user@remote-host
```

Pros:
- Can prove egress differs from host.
- Closer to final upstream provider-in-VM architecture.

Cons:
- More moving parts.

Recommended path:
1. Start with local `3proxy` (preferred; if Homebrew has no formula on the machine, build it from <https://github.com/3proxy/3proxy> or use the Python SOCKS logger below for protocol-only validation).
2. Then validate with `ssh -D` to a remote server or lightweight VM.

---

## Test App Strategy

We need a controlled app with a known bundle ID. Avoid testing first with Safari/Chrome/Teams because they create many background flows.

### Option 1 — Use existing `ShuntTest`

`Sources/ShuntTest/main.swift` already appears designed for proxy/direct HTTP checks.

Build:

```bash
cd /path/to/shunt
swift build -c release --product ShuntTest
```

Bundle it via `Scripts/build.sh` if system extension install flow requires app bundle identity.

### Option 2 — Add a tiny signed `TrafficProbe.app`

A minimal macOS app that performs one URL request to:

```text
https://ifconfig.me/ip
https://example.com/
https://httpbin.org/ip
```

Bundle ID:

```text
com.craraque.shunt.trafficprobe
```

This is the cleanest for rule matching because `sourceAppSigningIdentifier` should be deterministic.

---

## Phase 0 — Baseline Checks

### Task 0.1: Confirm repo state

```bash
cd /path/to/shunt
git status --short --branch
swift test --package-path .
swift build -c release --arch arm64 --product Shunt
swift build -c release --arch arm64 --product ShuntProxy
```

Expected:
- Clean branch or known local branch.
- Tests pass.
- Release builds pass.

### Task 0.2: Confirm system extension dev mode

```bash
systemextensionsctl developer
```

If not enabled:

```bash
sudo systemextensionsctl developer on
```

Expected:
- Dev mode enabled after reboot if needed.

---

## Phase 1 — Proxy Harness

### Task 1.1: Start SOCKS5 proxy with 3proxy

Preferred:

```bash
brew install 3proxy
cd /path/to/shunt
3proxy poc/3proxy-minimal.cfg
```

If `poc/3proxy-minimal.cfg` is not compatible with the current machine, create a temporary config:

```bash
cat > /tmp/shunt-3proxy.cfg <<'EOF'
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /tmp/shunt-3proxy.log D
logformat "L%Y-%m-%d %H:%M:%S %N.%p %E %U %C:%c -> %R:%r %O %I"
auth none
allow * 127.0.0.1
socks -p1080 -i127.0.0.1 -e127.0.0.1
EOF
3proxy /tmp/shunt-3proxy.cfg
```

Expected:
- Process listening on `127.0.0.1:1080`.

Verify:

```bash
nc -vz 127.0.0.1 1080
curl --socks5-hostname 127.0.0.1:1080 https://ifconfig.me/ip
curl https://ifconfig.me/ip
```

Expected:
- SOCKS curl succeeds.
- Direct curl succeeds.
- `/tmp/shunt-3proxy.log` shows the SOCKS request.

### Task 1.2: Capture proxy activity

If using microsocks, run it in a visible terminal/log session. For deeper SOCKS protocol verification, create a tiny Python SOCKS5 logger that logs:

- selected auth method
- ATYP
- destination host/IP
- destination port

Acceptance criteria:
- We can see whether Shunt sends ATYP `0x03` domain vs ATYP `0x01` IPv4.

---

## Phase 2 — Shunt Configuration

### Task 2.1: Configure upstream

In Shunt settings:

```text
SOCKS host: 127.0.0.1
SOCKS port: 1080
Use remote DNS: enabled
Auth: disabled
Bind interface: empty
```

Expected:
- Settings saved.
- Provider receives config on enable/reload.

### Task 2.2: Add one route rule

Rule:

```text
Name: Route TrafficProbe/ShuntTest
Action: Route
Apps: com.craraque.shunt.test or com.craraque.shunt.trafficprobe
Hosts: empty initially
```

Expected:
- Managed test app traffic is routed.
- Everything else remains direct.

### Task 2.3: Apply/reload

Use Shunt UI:

```text
Apply Rules / Reload Tunnel
```

Or if CLI/test hooks exist, use them.

Expected logs:

```text
applyRulesLive: provider ack=ok
CLAIM <bundle-id> → <host>:<port>
SKIP <other-bundle> ... no rule matched
```

---

## Phase 3 — Positive Routing Tests

### Task 3.1: Run managed test app to known host

Run test app against:

```text
https://ifconfig.me/ip
https://example.com/
```

Observe:

```bash
log stream --predicate 'subsystem == "com.craraque.shunt.proxy"' --info
```

Expected:
- `CLAIM` log for test app bundle ID.
- SOCKS proxy receives CONNECT.
- HTTP request succeeds.

### Task 3.2: Verify remote DNS / ATYP domain

Use a hostname target, not an IP literal:

```text
example.com:443
```

Expected in SOCKS logger:

```text
ATYP=0x03 host=example.com port=443
```

If it sends an IP instead:
- `useRemoteDNS` is not working or `remoteHostname` is unavailable for that flow.

### Task 3.3: Host-specific rule

Change rule to:

```text
Apps: TrafficProbe/ShuntTest bundle ID
Hosts: exact example.com
Action: route
```

Run:

```text
https://example.com/
https://ifconfig.me/ip
```

Expected:
- `example.com` claimed.
- `ifconfig.me` skipped/direct.

---

## Phase 4 — Negative / Passthrough Tests

### Task 4.1: Non-managed app direct path

While Shunt is enabled, run direct curl from Terminal:

```bash
curl https://example.com/
```

Expected:
- No SOCKS CONNECT caused by Terminal unless Terminal's bundle ID is in a route rule.
- Logs show `SKIP` or no claim.

### Task 4.2: Direct override rule

Create broader route and narrower direct rule:

```text
Rule A: app=TrafficProbe, host=*.example.com, action=route
Rule B: app=TrafficProbe, host=www.example.com, action=direct
```

Expected:
- Direct rule short-circuits for `www.example.com`.
- Broader route still works for other matching subdomains.

---

## Phase 5 — Failure Behavior

### Task 5.1: Proxy down

Stop SOCKS proxy while Shunt remains enabled.

Run managed test app.

Expected:
- Flow fails quickly and cleanly.
- No app/system hang.
- Provider logs a clear `socks connect failed`.

Current known risk:
- `POSIXTCPClient.connect()` is blocking. If upstream is a blackhole IP, this may hang too long.

### Task 5.2: Blackhole upstream

Set upstream to unroutable/slow address, e.g. a reserved IP in a non-responsive range.

Expected target behavior after fix:
- Timeout within configured threshold.
- No bridge leak.

This validates the need for non-blocking connect timeout.

---

## Phase 6 — Cleanup / Lifecycle Tests

### Task 6.1: Disable tunnel with active flow

Start a long-running request through managed app, then disable Shunt.

Expected after fix:
- `stopProxy` closes all bridges.
- Sockets close.
- `bridges` dictionary clears.
- No lingering flow activity.

### Task 6.2: Reload tunnel with active flow

Use Shunt reload while a managed app is active.

Expected:
- Old flows drop or close cleanly.
- New flows use updated settings.
- No duplicate providers/bridges.

---

## Phase 7 — Egress Difference Test

Only run after local SOCKS tests pass.

### Task 7.1: Use remote SOCKS via SSH

```bash
ssh -N -D 127.0.0.1:1080 user@remote-vps
```

Direct:

```bash
curl https://ifconfig.me/ip
```

Via SOCKS:

```bash
curl --socks5-hostname 127.0.0.1:1080 https://ifconfig.me/ip
```

Expected:
- IPs differ.

### Task 7.2: Run managed app through Shunt

Expected:
- Managed app reports remote VPS egress IP.
- Non-managed apps report host egress IP.

This is the clean proof that Shunt is doing selective per-app routing.

---

## Acceptance Criteria

Shunt is valid enough to continue if all are true:

1. Managed app TCP traffic produces `CLAIM` and reaches SOCKS.
2. Non-managed app traffic does not reach SOCKS.
3. Host-specific route/direct rules behave correctly.
4. `useRemoteDNS=true` sends hostname CONNECT where possible.
5. Disabling/reloading tunnel closes active bridges cleanly.
6. Proxy-down failure does not hang the app/system.
7. Remote SOCKS egress test proves managed and non-managed apps have different egress IPs.

---

## Recommended Fixes Before Full Validation

Before spending too much time on end-to-end tests, fix or verify:

1. Entitlements/plist alignment: Transparent Proxy vs App Proxy.
2. `stopProxy` bridge cleanup.
3. SOCKS5 IPv6 CONNECT support.
4. POSIX non-blocking connect timeout.
5. Redact network logs or gate detailed logs behind diagnostics.

---

## Execution Order

1. Create local branch.
2. Add/fix test harness if needed.
3. Validate with local `microsocks`.
4. Fix obvious blockers discovered by local tests.
5. Validate with remote `ssh -D` SOCKS egress.
6. Only after that, test with upstream provider/VM.
