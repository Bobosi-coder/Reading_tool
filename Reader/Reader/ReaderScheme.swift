import Foundation
import WebKit
import UniformTypeIdentifiers

/// Serves book files and imported fonts to the WebView from a single origin:
///   reader://local/book/<path inside epub>
///   reader://local/_fonts/<font file>
final class ReaderScheme: NSObject, WKURLSchemeHandler {
    static let scheme = "reader"
    static let bookPrefix = "reader://local/book/"
    static let fontPrefix = "reader://local/_fonts/"

    var bookFolder: URL

    init(bookFolder: URL) {
        self.bookFolder = bookFolder
    }

    static func url(forBookPath path: String, fragment: String? = nil) -> URL? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var s = bookPrefix + encoded
        if let fragment, !fragment.isEmpty { s += "#" + fragment }
        return URL(string: s)
    }

    /// Book-relative path for a reader:// URL, or nil.
    static func bookPath(for url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let path = url.path // decoded, starts with "/"
        guard path.hasPrefix("/book/") else { return nil }
        return String(path.dropFirst("/book/".count))
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let path = url.path
        let fileURL: URL
        if path.hasPrefix("/book/") {
            fileURL = bookFolder.appendingPathComponent(String(path.dropFirst("/book/".count)))
        } else if path.hasPrefix("/_fonts/") {
            fileURL = FontManager.fontsDirectory.appendingPathComponent(String(path.dropFirst("/_fonts/".count)))
        } else {
            fail(urlSchemeTask, url: url)
            return
        }

        // Stay inside the allowed folders.
        let resolved = fileURL.standardizedFileURL.path
        guard resolved.hasPrefix(bookFolder.standardizedFileURL.path) ||
              resolved.hasPrefix(FontManager.fontsDirectory.standardizedFileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            fail(urlSchemeTask, url: url)
            return
        }

        let mime = Self.mimeType(for: fileURL.pathExtension)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime,
            "Content-Length": "\(data.count)",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        ])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask, url: URL) {
        let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
        task.didReceive(response)
        task.didFinish()
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "xhtml", "xht", "xml", "opf", "ncx": return "application/xhtml+xml; charset=utf-8"
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js": return "text/javascript"
        case "svg": return "image/svg+xml"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "ttc", "otc": return "font/collection"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default:
            return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
