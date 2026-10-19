import SwiftUI

// Adaptive, static surfaces; no looping motion, blur or offscreen rendering.
enum ChaiPalette {
    static let accent = Color.indigo
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let outline = Color(uiColor: .separator).opacity(0.30)
}

struct ChaiPanel: ViewModifier {
    var tint: Color = .indigo
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(ChaiPalette.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.09), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(ChaiPalette.outline, lineWidth: 0.5)
                }
        }
    }
}
