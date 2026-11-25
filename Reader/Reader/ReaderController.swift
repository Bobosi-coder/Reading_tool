import SwiftUI
import WebKit
import Observation

enum AIQuickAction: String {
    case ask, translateExplain

    var title: String {
        switch self {
        case .ask: "问 AI"
        case .translateExplain: "译 · 释"
        }
    }

    var symbol: String {
        switch self {
        case .ask: "sparkles"
        case .translateExplain: "character.bubble"
        }
    }

    /// Short label shown in the chat bubble.
    var label: String {
        switch self {
        case .ask: "这段话讲的是什么意思？"
        case .translateExplain: "翻译并解释"
        }
    }

    var prompt: String {
        switch self {
        case .ask: "这段话讲的是什么意思？"
        case .translateExplain: """
            请先翻译，再解释：
            1. **翻译**：英文（或其他外语）译成自然流畅的中文；中文译成英文。
            2. **解释**：挑出难词、短语和习语（英文词附音标与词性），拆解长难句的语法结构，并补充理解所需的背景。
            用 **翻译** 和 **解释** 两个小标题分段，简洁清楚。
            """
        }
    }
}

enum TurnDirection { case forward, backward }

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
    /// Hosts the web view plus the snapshot layer used for page-turn animations.
    let container: ReaderContainerView

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
    @ObservationIgnored private var turnInFlight: TurnDirection?
    @ObservationIgnored private var turnTimeout: DispatchWorkItem?

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
        container = ReaderContainerView(webView: webView)
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
        #if DEBUG
        webView.isInspectable = true
        #endif
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

    func nextPage() { turn(.forward) }
    func prevPage() { turn(.backward) }

    // MARK: - Page turning

    private var atBookStart: Bool { spineIndex == 0 && page == 0 }
    private var atBookEnd: Bool { spineIndex >= epub.spine.count - 1 && page >= pageCount - 1 }

    private func turnJS(_ dir: TurnDirection) {
        webView.evaluateJavaScript(dir == .forward ? "window.reader && reader.next()" : "window.reader && reader.prev()")
    }

    /// Snapshot the current page, move the content, then animate from the snapshot to the new page.
    func turn(_ dir: TurnDirection) {
        guard turnInFlight == nil else { return }
        if (dir == .forward && atBookEnd) || (dir == .backward && atBookStart) { return }
        let style = ReaderSettings.shared.pageTurn
        guard style != .none else { turnJS(dir); return }

        turnInFlight = dir
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self else { return }
            guard let image else { self.turnInFlight = nil; self.turnJS(dir); return }
            self.container.showSnapshot(image)
            self.turnJS(dir)
            let timeout = DispatchWorkItem { [weak self] in self?.finishTurn() }
            self.turnTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: timeout)
        }
    }

    /// Called once the web view reports the new position.
    private func completeTurn(chapterChanged: Bool) {
        guard let dir = turnInFlight else { return }
        let delay = chapterChanged ? 0.12 : 0.04
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.webView.takeSnapshot(with: nil) { [weak self] image, _ in
                guard let self else { return }
                guard let image else { self.finishTurn(); return }
                self.turnTimeout?.cancel()
                self.container.animate(to: image, direction: dir, style: ReaderSettings.shared.pageTurn) { [weak self] in
                    self?.finishTurn()
                }
            }
        }
    }

    private func finishTurn() {
        turnTimeout?.cancel()
        turnTimeout = nil
        turnInFlight = nil
        container.hideSnapshot()
    }

    func nextChapter() {
        if spineIndex + 1 < epub.spine.count { open(spineIndex: spineIndex + 1) }
    }

    func prevChapter(atEnd: Bool = true) {
        if spineIndex > 0 { open(spineIndex: spineIndex - 1, progress: atEnd ? 1 : 0) }
    }

    @objc private func swipeLeft() { turn(.forward) }
    @objc private func swipeRight() { turn(.backward) }

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
            self.webView.evaluateJavaScript("window.reader && reader.clearSelection()")
            self.hasSelection = false
        }
    }
}

// MARK: - WKNavigationDelegate

extension ReaderController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let frag = pendingTarget.fragment.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" } ?? "null"
        webView.evaluateJavaScript("reader.start({progress: \(pendingTarget.progress), fragment: \(frag)})") { _, error in
            if let error { NSLog("[Reader] start error: \(error)") }
        }
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
                    webView.evaluateJavaScript("reader.moved = true; reader.goToElement(\"\(fragment.replacingOccurrences(of: "\"", with: ""))\")")
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
            if turnInFlight != nil { completeTurn(chapterChanged: body["start"] as? Bool ?? false) }
        case "nextChapter":
            nextChapter()
        case "prevChapter":
            prevChapter()
        case "tap":
            switch body["zone"] as? String {
            case "left": turn(.backward)
            case "right": turn(.forward)
            default: withAnimation(.easeInOut(duration: 0.25)) { showChrome.toggle() }
            }
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

/// WKWebView with "问 AI" and "译 · 释" added to the text-selection menu.
final class PagingWebView: WKWebView {
    var onAIAction: ((AIQuickAction) -> Void)?

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        let actions: [UIAction] = [AIQuickAction.ask, .translateExplain].map { action in
            UIAction(title: action.title, image: UIImage(systemName: action.symbol)) { [weak self] _ in self?.onAIAction?(action) }
        }
        let menu = UIMenu(title: "", identifier: UIMenu.Identifier("reader.ai"), options: .displayInline, children: actions)
        if builder.menu(for: .standardEdit) != nil {
            builder.insertSibling(menu, beforeMenu: .standardEdit)
        } else {
            builder.insertChild(menu, atStartOfMenu: .root)
        }
    }
}

/// The web view with a snapshot image on top, used to play page-turn transitions.
final class ReaderContainerView: UIView {
    let webView: WKWebView
    private let snapshotView = UIImageView()

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        snapshotView.contentMode = .scaleToFill
        snapshotView.isHidden = true
        snapshotView.isUserInteractionEnabled = true // swallow taps mid-animation
        addSubview(snapshotView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        snapshotView.frame = webView.frame
    }

    func showSnapshot(_ image: UIImage) {
        snapshotView.layer.removeAllAnimations()
        snapshotView.image = image
        snapshotView.isHidden = false
    }

    func hideSnapshot() {
        snapshotView.isHidden = true
        snapshotView.image = nil
    }

    func animate(to image: UIImage, direction: TurnDirection, style: PageTurnStyle, completion: @escaping () -> Void) {
        let t = CATransition()
        switch style {
        case .curl:
            // Same page-curl transition UIKit uses for UIPageViewController.
            t.type = CATransitionType(rawValue: direction == .forward ? "pageCurl" : "pageUnCurl")
            t.subtype = direction == .forward ? .fromRight : .fromRight
            t.duration = 0.55
        case .slide, .none:
            t.type = .push
            t.subtype = direction == .forward ? .fromRight : .fromLeft
            t.duration = 0.32
        }
        #if DEBUG
        if let slow = ProcessInfo.processInfo.environment["TURN_DURATION"].flatMap(Double.init) { t.duration = slow }
        #endif
        t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        snapshotView.layer.add(t, forKey: "turn")
        snapshotView.image = image
        CATransaction.commit()
    }
}

struct ReaderWebView: UIViewRepresentable {
    let controller: ReaderController

    func makeUIView(context: Context) -> ReaderContainerView { controller.container }
    func updateUIView(_ uiView: ReaderContainerView, context: Context) {}
}
