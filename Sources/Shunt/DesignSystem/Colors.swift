import SwiftUI

// Shunt design system — color tokens.
// Source of truth: DESIGN.md §Color.

extension Color {
    /// Primary brand + primary action. Used for focus, active sidebar row, primary button.
    static let signalAmber = Color(red: 232.0/255, green: 134.0/255, blue: 15.0/255)
    /// Hover / secondary emphasis on amber surfaces.
    static let signalAmber500 = Color(red: 245.0/255, green: 158.0/255, blue: 47.0/255)
    /// Subtle fills — active sidebar row background, hero status card seed.
    static let signalAmber100 = Color(red: 253.0/255, green: 241.0/255, blue: 220.0/255)

    /// Reserved for "routing active" semantics only. Menubar active dot, status pill.
    static let pcbGreen = Color(red: 34.0/255, green: 197.0/255, blue: 94.0/255)
    /// Status pill background for the routing-active state.
    static let pcbGreen100 = Color(red: 220.0/255, green: 252.0/255, blue: 231.0/255)

    /// Warm-neutral window background, not sterile #FFFFFF.
    static let shuntWindowBackground = Color(nsColor: .windowBackgroundColor)
    /// System separator — adapts Light/Dark automatically.
    static let shuntSeparator = Color(nsColor: .separatorColor)
}
