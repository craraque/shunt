# Apple Network Extension Entitlement Request — Draft

Ready-to-send draft for <https://developer.apple.com/contact/network-extension>.

**Prerequisite:** Apple Developer Program membership active (✅ as of 2026-04-20, valid through 2027-04-21). Team ID: **6NSZVJU6BP**.

**Bundle IDs must be registered first** in Certificates, Identifiers & Profiles:
- `com.craraque.shunt`
- `com.craraque.shunt.proxy`

---

## Form fields

- **Name:** Cesar Araque
- **Email:** cesar.araque@gmail.com
- **Team ID:** `6NSZVJU6BP`
- **App name:** Shunt
- **Entitlement requested:** `com.apple.developer.networking.networkextension` — value `transparent-proxy-systemextension`
- **Distribution:** Outside the Mac App Store (Developer ID + notarization)

## Subject

Network Extension Entitlement Request — Transparent Proxy System Extension (Team ID 6NSZVJU6BP)

## Body

We are requesting `transparent-proxy-systemextension` under `com.apple.developer.networking.networkextension` for bundle ID `com.craraque.shunt` (container) and `com.craraque.shunt.proxy` (system extension).

Shunt is a macOS utility for bring-your-own-device (BYOD) professionals. It allows the user to designate a list of corporate applications (e.g. Microsoft Teams, Microsoft Outlook) whose outbound TCP/UDP flows are forwarded to a user-controlled, locally-running virtual machine that runs the user's corporate VPN client. All other flows are passed through to the system's default network path unchanged.

The goal is **per-application network segmentation** on personal devices: keeping the user's personal traffic off the corporate VPN while still giving their corporate applications the network environment those applications require. This is the inverse of a whole-system VPN — we only claim flows the user has explicitly opted into, identified by `sourceAppSigningIdentifier`, and we never modify, inspect, or intercept the bytes of flows we pass through.

Shunt will be distributed outside the Mac App Store, signed with our Developer ID Application certificate, notarized, and installed by the user with explicit System Extension approval in System Settings → Login Items & Extensions. No MDM is used. No flow content is read or logged by Shunt; the VM's corporate VPN client is the sole destination for claimed flows.

Happy to provide a demo build or additional detail.

Thanks,
Cesar Araque

---

## Language to avoid (per RESEARCH.md §4.4)

- "bypass" / "evade" / "hide"
- "VPN avoidance"
- Anything that frames this as circumventing the corporate network

## If Apple pushes back (per RESEARCH.md §4.5)

- **"Use a lower-privilege API."** → Explain why PAC / content filter / NEVPN don't fit (see RESEARCH.md §1).
- **"Sounds like a VPN bypass tool."** → Reframe: *segmentation, per-app, user-controlled, inverse of whole-system VPN*.
- **"We need to see what the extension does."** → Offer a pre-built demo binary or screen recording.
- **Silence ≥2 weeks.** → Polite re-ping with the same request.

Expected timeline: 1–4 weeks first response, 4–8 weeks to approved provisioning profile.
