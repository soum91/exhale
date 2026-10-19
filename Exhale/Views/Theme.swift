import SwiftUI

enum Theme {
    static let bgTop = Color(red: 0.05, green: 0.07, blue: 0.09)
    static let bgBottom = Color(red: 0.02, green: 0.03, blue: 0.04)
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.08)
    static let off = Color(white: 0.45)

    static func background(_ accent: Color) -> some View {
        ZStack {
            LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [accent.opacity(0.25), .clear], center: .top, startRadius: 10, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.5))
    }
}
