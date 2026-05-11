import AppKit
import SwiftUI

/// Renders the current theme's `ShuntLogo` to an `NSImage` and writes it as
/// the *custom* bundle icon for `Shunt.app` and `ShuntTest.app`. macOS picks
/// up custom icons in Finder Get Info, the Login Items list, system-issued
/// dialogs ("Shunt would like to…"), and notification badges, so the bundle
/// icon stays in sync with the in-app theme without needing 4 prerendered
/// `.icns` files shipped in `Resources/`.
///
/// Implementation notes:
/// - Renders at 1024×1024 first (max icon resolution macOS asks for) and adds
///   downsized representations at every standard size so the system can pick
///   the closest match without relying on its own scaler.
/// - `NSWorkspace.setIcon(_:forFile:options:)` writes the icon resource into
///   the `Icon\r` file inside the bundle. Requires write access to the
///   bundle's parent dir; for `/Applications/Shunt.app` that's the user's
///   own perms in modern macOS without admin escalation.
/// - Silent on failure — the only "user-facing" symptom of a permission
///   issue is that the bundle icon doesn't update; not worth blocking app
///   launch over.
@MainActor
enum BundleIconUpdater {

    /// Re-render and apply the bundle icon for the current active theme.
    /// Idempotent — safe to call repeatedly (e.g. on every theme switch).
    static func applyForCurrentTheme() {
        let theme = ActiveTheme.shared.current
        guard let image = renderLogoImage(for: theme) else { return }
        let bundlePaths = candidateBundlePaths()
        for path in bundlePaths {
            // Don't fail loudly — setIcon returns Bool but its outcome
            // isn't actionable from here.
            _ = NSWorkspace.shared.setIcon(image, forFile: path, options: [])
            // Also nudge Finder to refresh by touching the bundle's
            // modification date, which prompts the icon cache to re-read.
            // (No effect on Login Items; harmless.)
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: path
            )
        }
    }

    // MARK: - Rendering

    private static func renderLogoImage(for theme: ShuntTheme) -> NSImage? {
        let final = NSImage(size: NSSize(width: 1024, height: 1024))
        // Sizes macOS will request from Finder/Get Info/Login Items.
        // 1024 is the asset-catalog max; smaller reps below help the
        // system pick a sharp match without scaling-blur.
        let sizes: [CGFloat] = [1024, 512, 256, 128, 64, 32, 16]
        for size in sizes {
            guard let rep = render(theme: theme, size: size) else { continue }
            final.addRepresentation(rep)
        }
        return final.representations.isEmpty ? nil : final
    }

    private static func render(theme: ShuntTheme, size: CGFloat) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content:
            ShuntLogo(size: size, theme: theme)
                .frame(width: size, height: size)
        )
        // Render at 1× so the resulting bitmap dimensions equal `size`. macOS
        // recognises a rep with pixelsWide == size as the natural icon for
        // that point size.
        renderer.scale = 1.0
        guard let cgImage = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: size, height: size)
        return rep
    }

    // MARK: - Bundle discovery

    /// Both Shunt.app and ShuntTest.app, in `/Applications` (preferred) and
    /// the build output (developer convenience). De-duplicated by realpath
    /// so we never write to the same bundle twice.
    private static func candidateBundlePaths() -> [String] {
        var seen = Set<String>()
        var out: [String] = []

        func add(_ path: String) {
            let exists = FileManager.default.fileExists(atPath: path)
            guard exists else { return }
            let resolved = (path as NSString).resolvingSymlinksInPath
            guard !seen.contains(resolved) else { return }
            seen.insert(resolved)
            out.append(path)
        }

        // The currently-running bundle — most reliable target.
        add(Bundle.main.bundlePath)

        // Sibling test app, if installed alongside.
        let mainURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        let parent = mainURL.deletingLastPathComponent().path
        add("\(parent)/ShuntTest.app")
        add("\(parent)/Shunt.app")  // covers ShuntTest invoking from same dir

        // Standard install location regardless of where we're launched from.
        add("/Applications/Shunt.app")
        add("/Applications/ShuntTest.app")

        return out
    }
}
