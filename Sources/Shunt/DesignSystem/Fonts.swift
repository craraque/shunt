import SwiftUI

// Shunt design system — typography tokens.
// Source of truth: /Users/cesar/dev/shunt/DESIGN.md §Typography.

extension Font {
    /// 28pt semibold, SF Pro Display. About tab hero, onboarding.
    static let shuntDisplay = Font.system(size: 28, weight: .semibold, design: .default)
    /// 22pt semibold. Top-of-tab headers ("General", "Apps", ...).
    static let shuntTitle1 = Font.system(size: 22, weight: .semibold, design: .default)
    /// 17pt semibold. Subsections within a tab.
    static let shuntTitle2 = Font.system(size: 17, weight: .semibold, design: .default)
    /// 15pt regular body text. Descriptions, paragraphs.
    static let shuntBody = Font.system(size: 15, weight: .regular, design: .default)
    /// 13pt label. Form labels, menu items, buttons.
    static let shuntLabel = Font.system(size: 13, weight: .regular, design: .default)
    /// 13pt medium. Emphasized labels (selected sidebar row).
    static let shuntLabelStrong = Font.system(size: 13, weight: .medium, design: .default)
    /// 11pt caption. Footnotes, secondary metadata.
    static let shuntCaption = Font.system(size: 11, weight: .regular, design: .default)

    /// 13pt SF Mono with tabular-nums. IPs, ports, bundle IDs, interface names.
    static var shuntMonoData: Font {
        Font.system(size: 13, weight: .regular, design: .monospaced).monospacedDigit()
    }
    /// 11pt SF Mono medium, uppercase + tracked. Section headers like "PROXY".
    static var shuntMonoLabel: Font {
        Font.system(size: 11, weight: .medium, design: .monospaced)
    }
}
