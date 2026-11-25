import Foundation
import CoreText
import UIKit
import Observation
import SwiftUI

/// One font file the WebView can load via @font-face.
struct FontFile: Hashable {
    let family: String
    let fileName: String
    let url: URL
    let weightMin: Int
    let weightMax: Int
    let italic: Bool
    let bundled: Bool
}

enum FontScript { case cjk, latin }

/// A curated font shown at the top of the picker.
struct FeaturedFont: Identifiable, Hashable {
    let family: String     // CSS / CoreText family name
    let displayName: String
    let note: String
    let script: FontScript
    var id: String { family }
}

/// Manages bundled fonts, fonts the user imports (.ttf/.otf/.ttc), and system fonts.
@Observable
final class FontManager {
    static let shared = FontManager()

    private(set) var files: [FontFile] = []
    @ObservationIgnored private var registered: Set<URL> = []

    /// Use Apple's "New York" via the CSS ui-serif keyword.
    static let newYork = "New York"

    static var fontsDirectory: URL {
        let url = BookStore.documents.appendingPathComponent("Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var bundledDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true)
    }

    static let allowedExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]

    static let featured: [FeaturedFont] = [
        FeaturedFont(family: "LXGW WenKai", displayName: "霞鹜文楷", note: "温润的楷体，适合长时间阅读", script: .cjk),
        FeaturedFont(family: "LXGW Neo ZhiSong", displayName: "霞鹜新致宋", note: "清秀的宋体，书卷气", script: .cjk),
        FeaturedFont(family: "PingFang SC", displayName: "苹方", note: "系统黑体，清晰现代", script: .cjk),
        FeaturedFont(family: "Literata", displayName: "Literata", note: "接近 Bookerly 的电子书字体", script: .latin),
        FeaturedFont(family: newYork, displayName: "New York", note: "Apple 的阅读衬线体", script: .latin),
        FeaturedFont(family: "EB Garamond", displayName: "EB Garamond", note: "经典书籍字体", script: .latin),
        FeaturedFont(family: "Charter", displayName: "Charter", note: "端正耐读", script: .latin),
        FeaturedFont(family: "Iowan Old Style", displayName: "Iowan Old Style", note: "Apple 图书默认字体之一", script: .latin),
    ]

    private init() { reload() }

    // MARK: - Lists

    /// Families the user imported (not bundled), sorted.
    var importedFamilies: [String] {
        Array(Set(files.filter { !$0.bundled }.map(\.family))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func featured(for script: FontScript) -> [FeaturedFont] {
        Self.featured.filter { $0.script == script && isAvailable($0.family) }
    }

    func isAvailable(_ family: String) -> Bool {
        family == Self.newYork || files.contains { $0.family == family } || UIFont.familyNames.contains(family)
    }

    var systemFamilies: [String] {
        let known = Set(files.map(\.family)).union(Self.featured.map(\.family))
        return UIFont.familyNames.filter { !known.contains($0) }.sorted()
    }

    static func displayName(for family: String) -> String {
        if family.isEmpty { return "跟随书籍" }
        return featured.first { $0.family == family }?.displayName ?? family
    }

    /// Font for SwiftUI previews of a family.
    static func previewFont(_ family: String, size: CGFloat) -> Font {
        if family.isEmpty { return .system(size: size) }
        if family == newYork { return .system(size: size, design: .serif) }
        return .custom(family, size: size)
    }

    func url(forFile name: String) -> URL? {
        files.first { $0.fileName == name }?.url
    }

    // MARK: - Loading

    func reload() {
        var out: [FontFile] = []
        let fm = FileManager.default
        if let dir = Self.bundledDirectory, let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            out += items.filter { Self.allowedExtensions.contains($0.pathExtension.lowercased()) }
                .compactMap { Self.describe(url: $0, bundled: true) }
        }
        if let items = try? fm.contentsOfDirectory(at: Self.fontsDirectory, includingPropertiesForKeys: nil) {
            out += items.filter { Self.allowedExtensions.contains($0.pathExtension.lowercased()) }
                .compactMap { Self.describe(url: $0, bundled: false) }
        }
        files = out
        registerAllForUI()
    }

    /// Copy a picked font file into the app and register it. Returns the families added.
    func importFont(from source: URL) throws -> [String] {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        guard Self.allowedExtensions.contains(ext) else {
            throw NSError(domain: "Font", code: 1, userInfo: [NSLocalizedDescriptionKey: "只支持 .ttf / .otf / .ttc 字体文件"])
        }
        let fm = FileManager.default
        var written: [URL] = []

        if ext == "ttc" || ext == "otc" {
            // WebKit only uses the first face of a collection, so split it into one file per face.
            let data = try Data(contentsOf: source)
            let faces = try FontCollection.split(data)
            let base = source.deletingPathExtension().lastPathComponent
            for (i, face) in faces.enumerated() {
                let dest = Self.fontsDirectory.appendingPathComponent("\(base)-\(i).\(face.isCFF ? "otf" : "ttf")")
                try? fm.removeItem(at: dest)
                try face.data.write(to: dest)
                written.append(dest)
            }
        } else {
            let dest = Self.fontsDirectory.appendingPathComponent(source.lastPathComponent)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: source, to: dest)
            written.append(dest)
        }

        let described = written.compactMap { Self.describe(url: $0, bundled: false) }
        if described.isEmpty {
            written.forEach { try? fm.removeItem(at: $0) }
            throw NSError(domain: "Font", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法识别这个字体文件"])
        }
        reload()
        return Array(Set(described.map(\.family))).sorted()
    }

    func deleteFamily(_ family: String) {
        for f in files where f.family == family && !f.bundled {
            CTFontManagerUnregisterFontsForURL(f.url as CFURL, .process, nil)
            registered.remove(f.url)
            try? FileManager.default.removeItem(at: f.url)
        }
        let s = ReaderSettings.shared
        if s.latinFont == family { s.latinFont = ReaderSettings.defaultLatin }
        if s.cjkFont == family { s.cjkFont = ReaderSettings.defaultCJK }
        reload()
    }

    /// Register fonts in this process so SwiftUI previews can render them.
    func registerAllForUI() {
        for f in files where !registered.contains(f.url) {
            CTFontManagerRegisterFontsForURL(f.url as CFURL, .process, nil)
            registered.insert(f.url)
        }
    }

    /// @font-face rules so the WebView (separate process) can load the fonts in use.
    func fontFaceCSS(families: [String]) -> String {
        let wanted = Set(families)
        return files.filter { wanted.contains($0.family) }.map { f in
            let fmt = f.url.pathExtension.lowercased() == "otf" ? "opentype" : "truetype"
            let name = f.fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f.fileName
            let weight = f.weightMin == f.weightMax ? "\(f.weightMin)" : "\(f.weightMin) \(f.weightMax)"
            return """
            @font-face {
              font-family: "\(f.family)";
              src: url("\(ReaderScheme.fontPrefix)\(name)") format("\(fmt)");
              font-weight: \(weight);
              font-style: \(f.italic ? "italic" : "normal");
              font-display: block;
            }
            """
        }.joined(separator: "\n")
    }

    /// Alias family that covers only CJK code points, placed first in the font stack so
    /// Chinese always uses the chosen CJK font while Latin text falls through to the Latin font.
    static let cjkAlias = "Dive CJK"
    static let cjkUnicodeRange = "U+2E80-2FDF, U+3000-303F, U+3040-30FF, U+3100-312F, U+31A0-31BF, U+3200-33FF, U+3400-4DBF, U+4E00-9FFF, U+F900-FAFF, U+FE30-FE4F, U+FF00-FFEF, U+20000-2FA1F"

    func cjkAliasCSS(family: String) -> String {
        guard !family.isEmpty else { return "" }
        let own = files.filter { $0.family == family }
        if !own.isEmpty {
            return own.map { f in
                let fmt = f.url.pathExtension.lowercased() == "otf" ? "opentype" : "truetype"
                let name = f.fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f.fileName
                let weight = f.weightMin == f.weightMax ? "\(f.weightMin)" : "\(f.weightMin) \(f.weightMax)"
                return """
                @font-face {
                  font-family: "\(Self.cjkAlias)";
                  src: url("\(ReaderScheme.fontPrefix)\(name)") format("\(fmt)");
                  font-weight: \(weight);
                  font-style: \(f.italic ? "italic" : "normal");
                  unicode-range: \(Self.cjkUnicodeRange);
                  font-display: block;
                }
                """
            }.joined(separator: "\n")
        }
        // System font: reference it by its PostScript names.
        let names = UIFont.fontNames(forFamilyName: family)
        guard !names.isEmpty else { return "" }
        let regular = names.first { !$0.lowercased().contains("bold") && !$0.lowercased().contains("light") } ?? names[0]
        return """
        @font-face {
          font-family: "\(Self.cjkAlias)";
          src: local("\(regular)"), local("\(family)");
          unicode-range: \(Self.cjkUnicodeRange);
        }
        """
    }

    // MARK: - Helpers

    private static func describe(url: URL, bundled: Bool) -> FontFile? {
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let d = descs.first,
              let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String else { return nil }

        var weight = 400
        var italic = false
        if let traits = CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any] {
            if let w = traits[kCTFontWeightTrait] as? Double { weight = cssWeight(w) }
            if let sym = traits[kCTFontSymbolicTrait] as? UInt32 {
                italic = (sym & CTFontSymbolicTraits.traitItalic.rawValue) != 0
            }
        }
        if url.lastPathComponent.lowercased().contains("italic") { italic = true }

        // Variable fonts: expose the whole weight axis.
        var minW = weight, maxW = weight
        let font = CTFontCreateWithFontDescriptor(d, 12, nil)
        let wghtTag = 0x7767_6874 // 'wght'
        for axis in (CTFontCopyVariationAxes(font) as? [[CFString: Any]]) ?? [] {
            if (axis[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.intValue == wghtTag,
               let lo = (axis[kCTFontVariationAxisMinimumValueKey] as? NSNumber)?.intValue,
               let hi = (axis[kCTFontVariationAxisMaximumValueKey] as? NSNumber)?.intValue {
                minW = lo; maxW = hi
            }
        }
        return FontFile(family: family, fileName: url.lastPathComponent, url: url,
                        weightMin: minW, weightMax: maxW, italic: italic, bundled: bundled)
    }

    /// Map CoreText weight (-1...1) to CSS weight.
    private static func cssWeight(_ w: Double) -> Int {
        let table: [(Double, Int)] = [(-0.8, 100), (-0.6, 200), (-0.4, 300), (0.0, 400), (0.23, 500), (0.3, 600), (0.4, 700), (0.56, 800), (0.62, 900)]
        return table.min { abs($0.0 - w) < abs($1.0 - w) }?.1 ?? 400
    }
}

