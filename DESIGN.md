# Design System — Shunt

## Product Context
- **What this is:** Native macOS menu-bar utility that routes outbound TCP traffic from user-selected apps through a configurable SOCKS5 upstream, leaving every other app on the host network.
- **Who it's for:** macOS power users — developers, BYOD corporate workers, security researchers, people who want selective traffic routing without a device-wide VPN.
- **Space/industry:** macOS developer & network utilities. Reference peers: Proxyman, Little Snitch, Charles Proxy, Tailscale.
- **Project type:** Native macOS app (SwiftUI + AppKit, Apple Silicon, Developer ID distribution). Not a web product.

## Aesthetic Direction
- **Direction:** Precision Utility — electrical schematic meets macOS HIG. Clean, geometrically precise, confident.
- **Decoration level:** Intentional. Mostly minimal (typography-first), with one purposeful decorative layer: a subtle blueprint-grid motif on the About tab and empty states. Nowhere else.
- **Mood:** The product feels like a well-made lab instrument — quiet, exact, trusted. Opposite of "friendly onboarding SaaS" and opposite of "Engineer's Tool 2005".
- **What Shunt does NOT do:** gradients (flat colors only), colored neon outlines, purple accents, 3-column feature grids, emoji icons, glossy button chrome, skeuomorphism, Lobster font, kitschy terminal green, stock-photo hero sections.

## Typography

All fonts are system-provided on macOS 14+. No custom font files to bundle.

- **Display/Hero:** SF Pro Display (via `system-ui` or `-apple-system`) — 600 weight, `-0.01em` to `-0.02em` tracking on large sizes. Used for: About tab title, top-of-tab headers.
- **Body/UI:** SF Pro Text — 400 weight primary, 500 for labels, 600 for emphasis. Default `system-ui` on macOS. Used for: all human-readable UI strings, descriptions, menu items, buttons.
- **Technical (Mono):** SF Mono with `font-variant-numeric: tabular-nums`. Used for: bundle IDs, IPs, ports, interface names, SOCKS5 host:port, designated requirements, status output, version/build strings. **Required wherever network data appears, even inside labels and tables.**
- **Section labels (Mono uppercase):** SF Mono, 11pt, 500 weight, `letter-spacing: 0.08–0.10em`, uppercase, Signal Amber tint. Used for: tab subsection headers ("PROXY", "ABOUT THIS VERSION"), preview section markers.

### Type scale (pt, macOS HIG-aligned)

| Role | Size | Weight | Family | Notes |
|---|---|---|---|---|
| Display | 28 | 600 | SF Pro Display | About tab hero, onboarding |
| Title 1 | 22 | 600 | SF Pro Display | Top of Settings tab ("General", "Apps", …) |
| Title 2 | 17 | 600 | SF Pro Display | Subsections |
| Body | 15 | 400 | SF Pro Text | Descriptions, explanations |
| Label | 13 | 400–500 | SF Pro Text | Form labels, menu items |
| Caption | 11 | 400 | SF Pro Text | Footnotes, secondary metadata |
| Mono — data | 13 | 400 | SF Mono | IPs, ports, bundle IDs (tabular-nums) |
| Mono — label | 11 | 500 | SF Mono | Section headers (uppercase, tracked) |

### SwiftUI font tokens

```swift
extension Font {
    static let shuntDisplay     = Font.system(size: 28, weight: .semibold, design: .default)
    static let shuntTitle1      = Font.system(size: 22, weight: .semibold, design: .default)
    static let shuntTitle2      = Font.system(size: 17, weight: .semibold, design: .default)
    static let shuntBody        = Font.system(size: 15, weight: .regular, design: .default)
    static let shuntLabel       = Font.system(size: 13, weight: .regular, design: .default)
    static let shuntCaption     = Font.system(size: 11, weight: .regular, design: .default)
    static let shuntMonoData    = Font.system(size: 13, weight: .regular, design: .monospaced)
    static let shuntMonoLabel   = Font.system(size: 11, weight: .medium, design: .monospaced)
}
```

All mono text should apply `.monospacedDigit()` modifier for tabular-nums.

## Color

- **Approach:** Restrained. Two brand colors (Signal Amber primary, PCB Green reserved for one specific meaning), system neutrals everywhere else so light/dark mode works for free.
- **Zero gradients in the UI.** Flat colors only. The app icon uses a single subtle top-to-bottom background gradient (dark to darker); nothing else.

### Palette

| Token | Hex | Role |
|---|---|---|
| `--amber-600` | `#E8860F` | Primary brand, primary buttons, active sidebar item, focus outline |
| `--amber-500` | `#F59E2F` | Hover state on primary, secondary emphasis |
| `--amber-400` | `#FBB040` | Disabled primary (rare) |
| `--amber-100` | `#FDF1DC` | Subtle fills — active sidebar row background, hero status card gradient seed |
| `--green-600` | `#22C55E` | **Reserved:** routing-active indicator only (menubar dot, status pill, "connected" text, health check OK) |
| `--green-100` | `#DCFCE7` | Status pill background |
| `Text primary` | `labelColor` (system) | Primary text — adapts Light/Dark |
| `Text secondary` | `secondaryLabelColor` | Secondary text, form labels, descriptions |
| `Text tertiary` | `tertiaryLabelColor` | Placeholders, disabled, caption meta |
| `Window bg` | `#FBFBFA` / dark: `#1A1A19` | Warm-neutral, not sterile `#FFFFFF` |
| `Sidebar bg` | `NSVisualEffectView material: .sidebar` | Native vibrancy, not a solid color |
| `Titlebar bg` | `NSVisualEffectView material: .titlebar` | Native |
| `Border` | `separatorColor` (system) | Adapts Light/Dark |

### Dark mode

- Use system `labelColor` / `secondaryLabelColor` etc. — never hardcode `#1C1B1A`.
- Reduce Signal Amber saturation ~10% in dark mode to prevent eye strain; in practice, use the same hex and let the eye settle — only adjust if user feedback says it glares.
- Blueprint grid motif opacity drops from ~8% (light) to ~5% (dark).

### Semantic usage rules

- **Never** use Signal Amber for destructive actions. Use system red (`NSColor.systemRed`) for "Remove", "Deactivate", "Reset", "Delete".
- **Never** use PCB Green for a success/confirmation button (buttons are Amber or neutral). Green is a status-only color.
- **Never** use both Amber and Green in the same button.
- Error/warning states use system colors (`NSColor.systemRed`, `NSColor.systemYellow`).

## Spacing

- **Base unit:** 4pt. All spacing values are multiples of 4.
- **Density:** Comfortable — closer to Apple's System Settings than to a dense DAW.
- **Scale:**

| Token | Value | Usage |
|---|---|---|
| `xs` | 4pt | Tight inline gaps (icon ↔ label) |
| `sm` | 8pt | Toggle ↔ label |
| `md` | 12pt | Row vertical padding |
| `lg` | 16pt | Row horizontal padding, form-row gap |
| `xl` | 20pt | Section gap |
| `2xl` | 28pt | Tab content padding (top/bottom) |
| `3xl` | 32pt | Tab content padding (left/right) |
| `4xl` | 48pt | Page-level separations (About tab hero) |

- **Form row pattern:** 160pt label column + flexible value column, 10pt vertical padding, 1px bottom separator (except last row in section).
- **Settings window size:** 820pt × 520pt (sidebar 200pt + detail 620pt).

## Layout

- **Approach:** Grid-disciplined macOS HIG. No creative-editorial asymmetry.
- **Settings window structure:** `NSSplitView` with a fixed-width sidebar (`NSVisualEffectView` material `.sidebar`) on the left and a scrollable detail pane on the right. Five sidebar items: General, Apps, Upstream, Advanced, About.
- **Sidebar item:** 14pt SF Symbol icon + 13pt SF Pro label, 8pt horizontal padding, 6pt vertical. Active state: Amber 100 fill (`rgba(232,134,15,0.12)`) and Amber 600 text color.
- **Border radius scale:**
  - `sm` = 4pt → form inputs, list rows, secondary buttons
  - `md` = 8pt → cards, status pills
  - `lg` = 12pt → Settings window, primary surfaces
  - `icon` = 22% of icon size → macOS app icon (Apple HIG standard)

## Motion

- **Approach:** Minimal-functional. No custom animations in v0.1.
- **Allowed:** System-provided transitions (sidebar selection, window resize, toggle flip, form focus ring).
- **Duration:** System defaults — don't override.
- **Explicit non-goals for v0.1:** scroll-driven effects, stagger animations, spring physics on controls, menubar icon pulse.
- **Exception:** status-pill dot can get a subtle `box-shadow` "signal glow" ring (3px, 20% alpha) when routing is active — static, no pulse.

## Iconography

### App icon (`.icns`)

The icon makes the product's name literal — a **railway shunt**: the siding track where a shunting locomotive diverts specific cars off the main line. Perfect visual metaphor for "route selected apps through an alternate path."

Canonical geometry (render at all required sizes per Apple HIG):

- **Canvas:** Rounded square, 22% corner radius (Apple's current macOS style). Sizes 16, 32, 64, 128, 256, 512, 1024 plus @2x.
- **Background:** Vertical linear gradient `#2B2A28` → `#1A1A19` (top to bottom). Dark neutral, flat feeling. Single subtle gradient (does not count as "decoration" per the system rules — it's depth, not color).
- **Foreground mark** (viewBox `0 0 160 160`):
  - **Main track — two parallel rails:** horizontal lines at y=99 and y=113, from x=22 to x=138, `#F2F1EE`, 3px stroke, rounded caps.
  - **Cross ties (sleepers):** 6 thin vertical rects (3×24px, rounded 1px) at x=24, 40, 56, 100, 116, 132 (y=94 to 118), fill `#E4E0D8` at 40% opacity. Gap between 56 and 100 is the switch area. Ties may be omitted at rendered size ≤32px for legibility.
  - **Switch point marker:** small dot at (78, 106), Signal Amber `#E8860F`, 3.5px radius.
  - **Siding — two parallel rails (Amber):** diverging upward-right from the switch point. Outer rail: `M 72 99 Q 92 72 126 52`. Inner rail: `M 84 113 Q 104 86 138 66`. Stroke `#E8860F`, 3px, rounded caps.
  - **Siding ties (optional, full-size only):** two small rotated rects along the siding at ~35° / 30°, fill `#FBB040` at 50% opacity. Omit at rendered size ≤48px.
- **No text, no bevel, no glow, no arrow heads.**
- **Size-responsive simplification rule:** at smaller target sizes, progressively drop detail to preserve legibility. ≥128px → full detail. 64-128px → main ties visible, siding ties dropped. 32-64px → no ties at all, just the two main rails + two siding rails + switch point. ≤24px → same as 32-64px but with stroke widths scaled 1.3× for crispness.
- Source SVG lives in `Resources/Icon.svg` (full detail variant) plus `Resources/Icon-compact.svg` (simplified variant for ≤64px). An export script (`Scripts/render-icon.sh`) rasterizes all `.icns` slots via `iconutil`.

### Menu bar icon

- **16×16pt SF-Symbol-compatible template** when proxy is idle (monochrome, follows menubar theme).
- When routing is active: **Signal Amber fill** on the shunt curve + **PCB Green dot** at the arrow terminus. The `button.image.isTemplate = false` mode is used in this state.
- Both variants live as inline SVG rendered into `NSImage` at app startup, so we don't ship raster menubar assets.

### In-app icons

- Prefer **SF Symbols** wherever one fits. Hand-drawn SVGs only when no SF Symbol matches (rare).
- Apply `.symbolRenderingMode(.monochrome)` plus `foregroundStyle(.secondary)` for idle, `.tint(.signalAmber)` for active states.

## UI Components

### Buttons
- **Primary:** Signal Amber 600 background, white foreground, 4pt radius, `font.shuntLabel` medium. Hover: Amber 500.
- **Secondary:** Elevated bg, 1px strong border, text primary. Hover: `--bg-row-hover`.
- **Destructive:** `NSColor.systemRed` background.
- **Ghost (inline):** No border, text only; used sparingly for "Reveal in Finder" and similar metadata links.

### Status pills
- Routing: PCB Green 100 bg, PCB Green 600 text+dot, 3px shadow ring around dot (the "signal glow").
- Idle: `rgba(107,106,103,0.12)` bg, text-secondary color, no glow.

### Form controls
- Inputs render their content in **SF Mono** whenever it is network data (IPs, ports, bundle IDs). Human text uses SF Pro.
- Focus outline: 2pt Amber 500 outline at 1pt offset (no glow, no color fade).
- Toggles: native SwiftUI `Toggle` styled with `.tint(.signalAmber)`.

### Status card (General tab hero)
- Subtle Signal-Amber-tinted background gradient from top-left, fading to transparent.
- Primary text: tab's current status sentence ("Routing 3 apps via Zscaler VM").
- Accessory: active/idle status pill on the right.

## Decisions Log

| Date | Decision | Rationale |
|---|---|---|
| 2026-04-21 | Initial design system created | `/design-consultation` after visual research of Proxyman, Little Snitch, Charles Proxy, Tailscale. Chose "Precision Utility" aesthetic to differentiate from all three: Signal Amber accent (not Proxyman blue, not Snitch yellow, not Tailscale red), SF Mono for network data as a first-class typographic class. |
| 2026-04-21 | Icon metaphor: railway shunt (not electrical schematic) | User feedback during preview: railway metaphor is stronger because it makes the product's name literal. A shunt is the siding track that lets a shunting locomotive divert specific cars off the main line — exact visual parallel to "route selected apps through an alternate path." Iconography rewritten with two parallel rails + ties + diverging siding. |
| 2026-04-21 | No custom animations in v0.1 | Focus on correctness first. System transitions are fine. Add motion in v0.2 if UX feedback demands it. |
| 2026-04-21 | Zero gradients in UI (icon excepted) | Precision aesthetic is undermined by glossy surfaces. Flat colors enforce discipline. |
| 2026-04-21 | Blueprint grid motif only on About tab | Signature decorative moment. Applying everywhere would be kitsch. About is the one "brand expression" surface. |
