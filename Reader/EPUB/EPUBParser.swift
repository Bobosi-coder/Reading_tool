import Foundation

struct SpineItem: Hashable {
    let id: String
    /// Path relative to the book root folder, without fragment.
    let path: String
}

struct TOCEntry: Identifiable, Hashable {
    let id = UUID()
    let title: String
    /// Path relative to the book root folder, without fragment.
    let path: String
    let fragment: String?
    let level: Int
}

struct EPUBBook {
    let title: String
    let author: String
    let language: String
    let spine: [SpineItem]
    let toc: [TOCEntry]
    /// Cover path relative to the book root ("" if none).
    let coverPath: String

    func spineIndex(forPath path: String) -> Int? {
        spine.firstIndex { $0.path == path }
    }

    /// Title of the TOC entry that best matches a spine index.
    func chapterTitle(forSpineIndex index: Int) -> String {
        guard spine.indices.contains(index) else { return "" }
        var best = ""
        for entry in toc {
            guard let i = spineIndex(forPath: entry.path) else { continue }
            // First entry pointing into this chapter is the chapter's own title.
            if i == index { return entry.title }
            if i < index { best = entry.title }
            if i > index { break }
        }
        return best
    }
}

enum EPUBError: LocalizedError {
    case missingContainer, missingOPF, emptySpine

    var errorDescription: String? {
        switch self {
        case .missingContainer: "找不到 META-INF/container.xml，不是有效的 EPUB。"
        case .missingOPF: "找不到 OPF 包文件。"
        case .emptySpine: "这本书没有可阅读的章节。"
        }
    }
}

enum EPUBParser {
    /// Parse an already-unzipped EPUB folder.
    static func parse(folder: URL) throws -> EPUBBook {
        guard let container = XMLTree.parse(url: folder.appendingPathComponent("META-INF/container.xml")) else {
            throw EPUBError.missingContainer
        }
        guard let opfPath = container.firstDescendant("rootfile")?["full-path"]?.removingPercentEncoding
                ?? container.firstDescendant("rootfile")?["full-path"],
              let opf = XMLTree.parse(url: folder.appendingPathComponent(opfPath)) else {
            throw EPUBError.missingOPF
        }
        let opfDir = Path.directory(of: opfPath)

        // Metadata
        let metadata = opf.firstDescendant("metadata")
        let title = metadata?.firstDescendant("title")?.allText.trimmed ?? ""
        let author = metadata?.descendants("creator").map { $0.allText.trimmed }.filter { !$0.isEmpty }.joined(separator: "、") ?? ""
        let language = metadata?.firstDescendant("language")?.allText.trimmed ?? ""

        // Manifest
        struct Item { let id, href, mediaType, properties: String }
        var manifest: [String: Item] = [:]
        var manifestOrder: [Item] = []
        for el in opf.firstDescendant("manifest")?.children("item") ?? [] {
            guard let id = el["id"], let href = el["href"] else { continue }
            let item = Item(id: id,
                            href: Path.resolve(base: opfDir, href: href),
                            mediaType: el["media-type"] ?? "",
                            properties: el["properties"] ?? "")
            manifest[id] = item
            manifestOrder.append(item)
        }

        // Spine
        let spineEl = opf.firstDescendant("spine")
        var spine: [SpineItem] = []
        for ref in spineEl?.children("itemref") ?? [] {
            guard let idref = ref["idref"], let item = manifest[idref] else { continue }
            if ref["linear"] == "no" && !spine.isEmpty { continue }
            spine.append(SpineItem(id: idref, path: Path.stripFragment(item.href)))
        }
        guard !spine.isEmpty else { throw EPUBError.emptySpine }

        // Cover
        var cover = manifestOrder.first { $0.properties.split(separator: " ").contains("cover-image") }?.href
        if cover == nil,
           let coverId = metadata?.descendants("meta").first(where: { $0["name"] == "cover" })?["content"],
           let item = manifest[coverId], item.mediaType.hasPrefix("image") {
            cover = item.href
        }
        if cover == nil {
            cover = manifestOrder.first { $0.mediaType.hasPrefix("image") && $0.id.lowercased().contains("cover") }?.href
        }

        // TOC: prefer EPUB3 nav, fall back to NCX.
        var toc: [TOCEntry] = []
        if let nav = manifestOrder.first(where: { $0.properties.split(separator: " ").contains("nav") }) {
            toc = parseNav(folder: folder, navPath: nav.href)
        }
        if toc.isEmpty {
            let ncxId = spineEl?["toc"]
            let ncx = ncxId.flatMap { manifest[$0] }
                ?? manifestOrder.first { $0.mediaType == "application/x-dtbncx+xml" }
            if let ncx { toc = parseNCX(folder: folder, ncxPath: ncx.href) }
        }
        if toc.isEmpty {
            toc = spine.enumerated().map { TOCEntry(title: "第 \($0.offset + 1) 节", path: $0.element.path, fragment: nil, level: 0) }
        }

        return EPUBBook(title: title.isEmpty ? "未命名" : title,
                        author: author,
                        language: language,
                        spine: spine,
                        toc: toc,
                        coverPath: cover ?? "")
    }

    private static func parseNav(folder: URL, navPath: String) -> [TOCEntry] {
        guard let root = XMLTree.parse(url: folder.appendingPathComponent(navPath)) else { return [] }
        let navs = root.descendants("nav")
        guard let nav = navs.first(where: { $0["type"] == "toc" }) ?? navs.first,
              let ol = nav.firstDescendant("ol") else { return [] }
        let base = Path.directory(of: navPath)
        var out: [TOCEntry] = []
        func walk(_ list: XNode, level: Int) {
            for li in list.children("li") {
                let a = li.child("a") ?? li.child("span")
                let title = a?.allText.collapsedWhitespace ?? ""
                if let href = a?["href"], !title.isEmpty {
                    let full = Path.resolve(base: base, href: href)
                    out.append(TOCEntry(title: title, path: Path.stripFragment(full), fragment: Path.fragment(full), level: level))
                }
                if let sub = li.child("ol") { walk(sub, level: level + 1) }
            }
        }
        walk(ol, level: 0)
        return out
    }

    private static func parseNCX(folder: URL, ncxPath: String) -> [TOCEntry] {
        guard let root = XMLTree.parse(url: folder.appendingPathComponent(ncxPath)),
              let navMap = root.firstDescendant("navMap") else { return [] }
        let base = Path.directory(of: ncxPath)
        var out: [TOCEntry] = []
        func walk(_ el: XNode, level: Int) {
            for p in el.children("navPoint") {
                let title = p.child("navLabel")?.firstDescendant("text")?.allText.collapsedWhitespace ?? ""
                if let src = p.child("content")?["src"], !title.isEmpty {
                    let full = Path.resolve(base: base, href: src)
                    out.append(TOCEntry(title: title, path: Path.stripFragment(full), fragment: Path.fragment(full), level: level))
                }
                walk(p, level: level + 1)
            }
        }
        walk(navMap, level: 0)
        return out
    }
}

/// Path helpers for archive-relative paths (always "/"-separated, no leading slash).
enum Path {
    static func directory(of path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return "" }
        return String(path[..<i])
    }

    static func stripFragment(_ path: String) -> String {
        path.split(separator: "#", maxSplits: 1).first.map(String.init) ?? path
    }

    static func fragment(_ path: String) -> String? {
        let parts = path.split(separator: "#", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }

    static func resolve(base: String, href: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        var comps = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        let frag = fragment(decoded)
        for c in stripFragment(decoded).split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { _ = comps.popLast(); continue }
            comps.append(String(c))
        }
        let joined = comps.joined(separator: "/")
        return frag.map { joined + "#" + $0 } ?? joined
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var collapsedWhitespace: String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
