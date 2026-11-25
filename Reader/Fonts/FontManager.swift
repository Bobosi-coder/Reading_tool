import Foundation
import CoreText
import UIKit
import Observation

struct ImportedFontFace: Hashable {
    let family: String
    let postScriptName: String
    let fileName: String
    let weight: Int      // CSS weight 100...900
    let italic: Bool
}

/// Manages font files the user imports (.ttf/.otf/.ttc), and the list of system fonts.
@Observable
final class FontManager {
    static let shared = FontManager()

    private(set) var faces: [ImportedFontFace] = []
    private var registered: Set<String> = []

    static var fontsDirectory: URL {
        let url = BookStore.documents.appendingPathComponent("Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let allowedExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]

    private init() { reload() }

    /// Families imported by the user, sorted.
    var importedFamilies: [String] {
        Array(Set(faces.map(\.family))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func files(forFamily family: String) -> [String] {
        Array(Set(faces.filter { $0.family == family }.map(\.fileName))).sorted()
    }

    func reload() {
        let dir = Self.fontsDirectory
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var out: [ImportedFontFace] = []
        for file in files where Self.allowedExtensions.contains((file as NSString).pathExtension.lowercased()) {
            out.append(contentsOf: Self.describe(url: dir.appendingPathComponent(file)))
        }
        faces = out
        registerAllForUI()
    }

    /// Copy a picked font file into the app and register it.
    func importFont(from source: URL) throws -> [String] {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        guard Self.allowedExtensions.contains(ext) else {
            throw NSError(domain: "Font", code: 1, userInfo: [NSLocalizedDescriptionKey: "只支持 .ttf / .otf / .ttc 字体文件"])
        }
        let dest = Self.fontsDirectory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        let described = Self.describe(url: dest)
        if described.isEmpty {
            try? FileManager.default.removeItem(at: dest)
            throw NSError(domain: "Font", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法识别这个字体文件"])
        }
        reload()
        return Array(Set(described.map(\.family)))
    }

    func deleteFamily(_ family: String) {
        for file in files(forFamily: family) {
            let url = Self.fontsDirectory.appendingPathComponent(file)
            CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
            registered.remove(file)
            try? FileManager.default.removeItem(at: url)
        }
        let s = ReaderSettings.shared
        if s.latinFont == family { s.latinFont = "" }
        if s.cjkFont == family { s.cjkFont = "" }
        reload()
    }

    /// Register imported fonts in this process so SwiftUI previews can render them.
    func registerAllForUI() {
        for file in Set(faces.map(\.fileName)) where !registered.contains(file) {
            let url = Self.fontsDirectory.appendingPathComponent(file)
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            registered.insert(file)
        }
    }

    /// @font-face rules so the WebView (separate process) can load the imported fonts.
    /// Only families currently in use are included to keep loading fast.
    func fontFaceCSS(families: [String]) -> String {
        let wanted = Set(families)
        return faces.filter { wanted.contains($0.family) }.map { f in
            let fmt: String
            switch (f.fileName as NSString).pathExtension.lowercased() {
            case "otf": fmt = "opentype"
            case "ttf": fmt = "truetype"
            default: fmt = "truetype"
            }
            let src = "\(ReaderScheme.fontPrefix)\(f.fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f.fileName)"
            return """
            @font-face {
              font-family: "\(f.family)";
              src: url("\(src)") format("\(fmt)");
              font-weight: \(f.weight);
              font-style: \(f.italic ? "italic" : "normal");
              font-display: block;
            }
            """
        }.joined(separator: "\n")
    }

    // MARK: - System fonts

    /// Nice reading fonts shipped with iPadOS, shown first when present.
    static let recommendedSystem: [String] = [
        "PingFang SC", "Songti SC", "Kaiti SC", "STKaiti", "Hiragino Mincho ProN",
        "Georgia", "Palatino", "Iowan Old Style", "Charter", "Baskerville",
        "Times New Roman", "Avenir Next", "Helvetica Neue", "Optima", "Didot",
    ]

    var systemFamilies: [String] {
        let imported = Set(importedFamilies)
        return UIFont.familyNames.filter { !imported.contains($0) }.sorted()
    }

    var recommendedSystemFamilies: [String] {
        let all = Set(UIFont.familyNames)
        return Self.recommendedSystem.filter { all.contains($0) }
    }

    // MARK: - Helpers

    private static func describe(url: URL) -> [ImportedFontFace] {
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return [] }
        return descs.compactMap { d in
            guard let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String else { return nil }
            let ps = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String ?? family
            var weight = 400
            var italic = false
            if let traits = CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any] {
                if let w = traits[kCTFontWeightTrait] as? Double { weight = cssWeight(w) }
                if let sym = traits[kCTFontSymbolicTrait] as? UInt32 {
                    italic = (sym & CTFontSymbolicTraits.traitItalic.rawValue) != 0
                }
            }
            return ImportedFontFace(family: family, postScriptName: ps, fileName: url.lastPathComponent, weight: weight, italic: italic)
        }
    }

    /// Map CoreText weight (-1...1) to CSS weight.
    private static func cssWeight(_ w: Double) -> Int {
        let table: [(Double, Int)] = [(-0.8, 100), (-0.6, 200), (-0.4, 300), (0.0, 400), (0.23, 500), (0.3, 600), (0.4, 700), (0.56, 800), (0.62, 900)]
        return table.min { abs($0.0 - w) < abs($1.0 - w) }?.1 ?? 400
    }
}
