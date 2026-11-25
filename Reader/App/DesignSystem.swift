import SwiftUI

/// Shared colors, type and small components for a calm, paper-like look.
enum DS {
    static let paper = Color(light: 0xF6F2EA, dark: 0x121214)
    static let card = Color(light: 0xFFFDF9, dark: 0x1C1C1F)
    static let ink = Color(light: 0x1F1C18, dark: 0xECE8E1)
    static let inkSoft = Color(light: 0x6E675E, dark: 0x9C978F)
    static let hairline = Color(light: 0xE4DDD1, dark: 0x2C2C30)

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Muted cover palettes for books without a cover image.
    static let coverPalettes: [(UInt32, UInt32)] = [
        (0x2F4858, 0x33658A), (0x5B4636, 0x8A6F4D), (0x3D405B, 0x6D6A8E),
        (0x264653, 0x2A9D8F), (0x6B3E4D, 0x9C5C6E), (0x3A5A40, 0x588157),
        (0x1D3557, 0x457B9D), (0x7F5539, 0xB08968),
    ]
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { trait in
            let v = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                           blue: CGFloat(v & 0xff) / 255, alpha: 1)
        })
    }

    init(rgb v: UInt32) {
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

/// Round frosted icon button.
struct GlassIconButton: View {
    let systemName: String
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(DS.ink)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(DS.hairline.opacity(0.6), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        }
        .buttonStyle(PressableStyle())
    }
}

/// Slight shrink on press.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Thin rounded progress bar.
struct ThinProgress: View {
    let value: Double
    var height: CGFloat = 4
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.hairline)
                Capsule().fill(tint).frame(width: max(height, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// Book cover: real image if present, otherwise a typeset cover.
struct BookCoverView: View {
    let title: String
    let author: String
    let coverURL: URL?

    var body: some View {
        ZStack {
            if let coverURL, let img = UIImage(contentsOfFile: coverURL.path) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                generated
            }
            // Spine highlight for a physical feel.
            HStack(spacing: 0) {
                LinearGradient(colors: [.white.opacity(0.28), .black.opacity(0.08), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 10)
                Spacer()
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(.black.opacity(0.06), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 6)
    }

    private var generated: some View {
        let palette = DS.coverPalettes[title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % DS.coverPalettes.count]
        return GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                LinearGradient(colors: [Color(rgb: palette.1), Color(rgb: palette.0)], startPoint: .top, endPoint: .bottom)
                RoundedRectangle(cornerRadius: 2)
                    .stroke(.white.opacity(0.35), lineWidth: 0.8)
                    .padding(w * 0.06)
                VStack(spacing: w * 0.05) {
                    Spacer()
                    Rectangle().fill(.white.opacity(0.6)).frame(width: w * 0.18, height: 1)
                    Text(title)
                        .font(DS.serif(w * 0.11, .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .minimumScaleFactor(0.6)
                    Rectangle().fill(.white.opacity(0.6)).frame(width: w * 0.18, height: 1)
                    Spacer()
                    Text(author)
                        .font(.system(size: w * 0.065, weight: .medium))
                        .tracking(1)
                        .lineLimit(1)
                        .opacity(0.85)
                        .padding(.bottom, w * 0.12)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, w * 0.14)
            }
        }
    }
}
