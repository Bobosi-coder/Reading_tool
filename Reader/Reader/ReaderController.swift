import SwiftUI
import WebKit
import Observation

enum AIQuickAction: String {
    case ask, explain, translate

    var prompt: String {
        switch self {
        case .ask: "这段话讲的是什么意思？"
        case .explain: "请解释这段话里的难点（词语、典故、背景、逻辑），并用通俗的话概括。"
        case .translate: "请翻译这段文字（中文译成英文，其他语言译成中文），并简要说明关键表达。"
        }
    }
}

struct SelectionPayload: Identifiable {
    let id = UUID()
    let text: String
    let context: String
    let action: AIQuickAction
    let chapterTitle: String
}

/// Owns the WKWebView and drives chapter loading + pagination.
@Observable
final class ReaderController: NSObject {
    let epub: EPUBBook
    let bookFolder: URL
    let webView: PagingWebView

    private(set) var spineIndex: Int = 0
    private(set) var page: Int = 0
    private(set) var pageCount: Int = 1
    private(set) var hasSelection = false
    var showChrome = false
    var askPayload: SelectionPayload?

    /// Called whenever the reading position changes (spineIndex, progress in chapter).
    @ObservationIgnored var onPositionChange: ((Int, Double) -> Void)?

    private let scheme: ReaderScheme
    @ObservationIgnored private var pendingTarget: (progress: Double, fragment: String?) = (0, nil)
    @ObservationIgnored private var appliedSignature = ""

    init(epub: EPUBBook, bookFolder: URL) {
        self.epub = epub
        self.bookFolder = bookFolder
        self.scheme = ReaderScheme(bookFolder: bookFolder)

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(scheme, forURLScheme: ReaderScheme.scheme)
        config.dataDetectorTypes = []
        config.suppressesIncrementalRendering = true
        let ucc = WKUserContentController()
        config.userContentController = ucc

        webView = PagingWebView(frame: .zero, configuration: config)
        super.init()

        ucc.add(WeakMessageHandler(self), name: "reader")
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.allowsLinkPreview = false
        webView.onAIAction = { [weak self] action in self?.requestAI(action) }

        let left = UISwipeGestureRecognizer(target: self, action: #selector(swipeLeft))
        left.direction = .left
        let right = UISwipeGestureRecognizer(target: self, action: #selector(swipeRight))
        right.direction = .right
        webView.addGestureRecognizer(left)
        webView.addGestureRecognizer(right)

        installUserScripts()
    }

    var chapterTitle: String { epub.chapterTitle(forSpineIndex: spineIndex) }

    var totalProgress: Double {
        guard !epub.spine.isEmpty else { return 0 }
        let inChapter = pageCount > 0 ? Double(page + 1) / Double(pageCount) : 0
        return (Double(spineIndex) + inChapter) / Double(epub.spine.count)
    }

    // MARK: - Loading

    func open(spineIndex: Int, progress: Double = 0, fragment: String? = nil) {
        guard epub.spine.indices.contains(spineIndex) else { return }
        self.spineIndex = spineIndex
        pendingTarget = (progress, fragment)
        hasSelection = false
        guard let url = ReaderScheme.url(forBookPath: epub.spine[spineIndex].path) else { return }
        webView.backgroundColor = UIColor(ReaderSettings.shared.theme.bgColor)
        webView.load(URLRequest(url: url))
    }

    func open(tocEntry: TOCEntry) {
        guard let i = epub.spineIndex(forPath: tocEntry.path) else { return }
        open(spineIndex: i, fragment: tocEntry.fragment)
    }

    func nextPage() { webView.evaluateJavaScript("window.reader && reader.next()") }
    func prevPage() { webView.evaluateJavaScript("window.reader && reader.prev()") }

    func nextChapter() {
        if spineIndex + 1 < epub.spine.count { open(spineIndex: spineIndex + 1) }
    }

    func prevChapter(atEnd: Bool = true) {
        if spineIndex > 0 { open(spineIndex: spineIndex - 1, progress: atEnd ? 1 : 0) }
    }

    @objc private func swipeLeft() { nextPage() }
    @objc private func swipeRight() { prevPage() }

    // MARK: - Styling

    private func currentCSS() -> String {
        ReaderJS.styleCSS(settings: .shared, fonts: .shared)
    }

    private func installUserScripts() {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: ReaderJS.startScript(css: currentCSS()), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: ReaderJS.runtime, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        appliedSignature = ReaderSettings.shared.signature
    }

    /// Re-apply typography after settings changed, keeping the reading position.
    func settingsChanged() {
        let sig = ReaderSettings.shared.signature
        guard sig != appliedSignature else { return }
        installUserScripts()
        webView.backgroundColor = UIColor(ReaderSettings.shared.theme.bgColor)
        let css = ReaderJS.jsonString(currentCSS())
        webView.evaluateJavaScript("window.reader && reader.applyStyle(\(css))")
    }

    // MARK: - AI

    func requestAI(_ action: AIQuickAction) {
        webView.evaluateJavaScript("JSON.stringify(window.reader ? reader.selectionInfo() : {})") { [weak self] result, _ in
            guard let self,
                  let json = result as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = obj["text"] as? String, !text.isEmpty else { return }
            let ctx = obj["context"] as? String ?? ""
            self.askPayload = SelectionPayload(text: text, context: ctx, action: action, chapterTitle: self.chapterTitle)
        }
    }
}

// MARK: - WKNavigationDelegate

extension ReaderController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let frag = pendingTarget.fragment.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" } ?? "null"
        webView.evaluateJavaScript("reader.start({progress: \(pendingTarget.progress), fragment: \(frag)})")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if let path = ReaderScheme.bookPath(for: url) {
            let fragment = url.fragment
            if let i = epub.spineIndex(forPath: path) {
                if i == spineIndex, let fragment {
                    webView.evaluateJavaScript("reader.goToElement(\"\(fragment.replacingOccurrences(of: "\"", with: ""))\")")
                } else {
                    open(spineIndex: i, fragment: fragment)
                }
            }
        } else if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Messages from JS

extension ReaderController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "position":
            page = body["page"] as? Int ?? 0
            pageCount = max(1, body["count"] as? Int ?? 1)
            let progress = Double(page) / Double(pageCount)
            onPositionChange?(spineIndex, progress)
        case "nextChapter":
            nextChapter()
        case "prevChapter":
            prevChapter()
        case "toggleChrome":
            withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
        case "selection":
            hasSelection = !((body["text"] as? String) ?? "").isEmpty
        default:
            break
        }
    }
}

/// Avoids the retain cycle WKUserContentController -> handler.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

/// WKWebView with "问 AI / 解释 / 翻译" added to the text-selection menu.
final class PagingWebView: WKWebView {
    var onAIAction: ((AIQuickAction) -> Void)?

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        let actions: [UIAction] = [
            UIAction(title: "问 AI", image: UIImage(systemName: "sparkles")) { [weak self] _ in self?.onAIAction?(.ask) },
            UIAction(title: "解释", image: UIImage(systemName: "text.magnifyingglass")) { [weak self] _ in self?.onAIAction?(.explain) },
            UIAction(title: "翻译", image: UIImage(systemName: "character.book.closed")) { [weak self] _ in self?.onAIAction?(.translate) },
        ]
        let menu = UIMenu(title: "", identifier: UIMenu.Identifier("reader.ai"), options: .displayInline, children: actions)
        if builder.menu(for: .standardEdit) != nil {
            builder.insertSibling(menu, beforeMenu: .standardEdit)
        } else {
            builder.insertChild(menu, atStartOfMenu: .root)
        }
    }
}

struct ReaderWebView: UIViewRepresentable {
    let controller: ReaderController

    func makeUIView(context: Context) -> PagingWebView { controller.webView }
    func updateUIView(_ uiView: PagingWebView, context: Context) {}
}
