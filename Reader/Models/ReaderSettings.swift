import SwiftUI
import Observation

enum ReaderTheme: String, CaseIterable, Identifiable {
    case light, sepia, green, dark

    var id: String { rawValue }

    var name: String {
        switch self {
        case .light: "白色"
        case .sepia: "米黄"
        case .green: "护眼"
        case .dark: "夜间"
        }
    }

    var background: String {
        switch self {
        case .light: "#ffffff"
        case .sepia: "#f4ecd8"
        case .green: "#cce8cf"
        case .dark: "#1c1c1e"
        }
    }

    var foreground: String {
        switch self {
        case .light: "#1a1a1a"
        case .sepia: "#4a3b28"
        case .green: "#22331f"
        case .dark: "#d6d6d6"
        }
    }

    var link: String {
        switch self {
        case .dark: "#7fb2ff"
        default: "#2a5db0"
        }
    }

    var bgColor: Color { Color(hex: background) }
    var fgColor: Color { Color(hex: foreground) }
    var isDark: Bool { self == .dark }
}

enum PageTurnStyle: String, CaseIterable, Identifiable {
    case curl, slide, none
    var id: String { rawValue }
    var name: String {
        switch self {
        case .curl: "仿真"
        case .slide: "滑动"
        case .none: "无"
        }
    }
}

/// All typography + theme preferences, persisted in UserDefaults.
@Observable
final class ReaderSettings {
    static let shared = ReaderSettings()

    private let d = UserDefaults.standard

    /// Font family name for Latin text ("" = follow book / system).
    var latinFont: String { didSet { d.set(latinFont, forKey: "latinFont") } }
    /// Font family name for CJK text ("" = follow book / system).
    var cjkFont: String { didSet { d.set(cjkFont, forKey: "cjkFont") } }
    var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize") } }
    var lineHeight: Double { didSet { d.set(lineHeight, forKey: "lineHeight") } }
    var letterSpacing: Double { didSet { d.set(letterSpacing, forKey: "letterSpacing") } }
    var paragraphSpacing: Double { didSet { d.set(paragraphSpacing, forKey: "paragraphSpacing") } }
    var horizontalMargin: Double { didSet { d.set(horizontalMargin, forKey: "horizontalMargin") } }
    var textIndent: Bool { didSet { d.set(textIndent, forKey: "textIndent") } }
    var justify: Bool { didSet { d.set(justify, forKey: "justify") } }
    var theme: ReaderTheme { didSet { d.set(theme.rawValue, forKey: "theme") } }
    var pageTurn: PageTurnStyle { didSet { d.set(pageTurn.rawValue, forKey: "pageTurn") } }

    static let defaultLatin = "Literata"
    static let defaultCJK = "LXGW WenKai"

    private init() {
        latinFont = d.string(forKey: "latinFont") ?? Self.defaultLatin
        cjkFont = d.string(forKey: "cjkFont") ?? Self.defaultCJK
        fontSize = d.object(forKey: "fontSize") as? Double ?? 19
        lineHeight = d.object(forKey: "lineHeight") as? Double ?? 1.75
        letterSpacing = d.object(forKey: "letterSpacing") as? Double ?? 0.02
        paragraphSpacing = d.object(forKey: "paragraphSpacing") as? Double ?? 0.6
        horizontalMargin = d.object(forKey: "horizontalMargin") as? Double ?? 36
        textIndent = d.object(forKey: "textIndent") as? Bool ?? true
        justify = d.object(forKey: "justify") as? Bool ?? true
        theme = ReaderTheme(rawValue: d.string(forKey: "theme") ?? "") ?? .sepia
        pageTurn = PageTurnStyle(rawValue: d.string(forKey: "pageTurn") ?? "") ?? .curl
    }

    /// CSS font-family value: Latin first so English uses it, CJK falls through.
    var fontFamilyCSS: String {
        var parts: [String] = []
        if !cjkFont.isEmpty { parts.append("\"\(FontManager.cjkAlias)\"") }
        if !latinFont.isEmpty {
            parts.append(latinFont == FontManager.newYork ? "ui-serif" : cssQuote(latinFont))
        }
        if !cjkFont.isEmpty && cjkFont != latinFont { parts.append(cssQuote(cjkFont)) }
        // Named CJK fallbacks: generic system families can fall through to blank glyphs.
        parts.append("\"PingFang SC\"")
        parts.append("serif")
        return parts.joined(separator: ", ")
    }

    var overridesFont: Bool { !latinFont.isEmpty || !cjkFont.isEmpty }

    /// Everything that affects layout, used to know when to re-render.
    var signature: String {
        "\(latinFont)|\(cjkFont)|\(fontSize)|\(lineHeight)|\(letterSpacing)|\(paragraphSpacing)|\(horizontalMargin)|\(textIndent)|\(justify)|\(theme.rawValue)"
    }

    private func cssQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(
            red: Double((v >> 16) & 0xff) / 255,
            green: Double((v >> 8) & 0xff) / 255,
            blue: Double(v & 0xff) / 255
        )
    }
}
