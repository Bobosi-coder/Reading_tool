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
final class ReaderController: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    let epub: EPUBBook
    let bookFolder: URL
    let webView: PagingWebView
    /// Hosts the web view plus the snapshot layer used for page-turn animations.
    let container: ReaderContainerView

    private(set) var spineIndex: Int = 0
    private(set) var page: Int = 0
    private(set) var pageCount: Int = 1
    private(set) var hasSelection = false {
        didSet { curlPan?.isEnabled = ReaderSettings.shared.pageTurn == .curl && !hasSelection }
    }
    var showChrome = false
    var askPayload: SelectionPayload?

    /// Called whenever the reading position changes (spineIndex, progress in chapter).
    @ObservationIgnored var onPositionChange: ((Int, Double) -> Void)?

    private let scheme: ReaderScheme
    @ObservationIgnored private var pendingTarget: (progress: Double, fragment: String?) = (0, nil)
    @ObservationIgnored private var appliedSignature = ""
    @ObservationIgnored private var turnInFlight: TurnDirection?
    @ObservationIgnored private var turnTimeout: DispatchWorkItem?

    // Interactive page curl (UIPageViewController over pre-rendered page images).
    @ObservationIgnored private let renderer: PageRenderer
    @ObservationIgnored private let pageVC: UIPageViewController
    @ObservationIgnored private var curlPan: UIGestureRecognizer?
    @ObservationIgnored private var swipes: [UISwipeGestureRecognizer] = []
    @ObservationIgnored private var currentVC: PageImageVC?
    @ObservationIgnored private var nextVC: PageImageVC?
    @ObservationIgnored private var prevVC: PageImageVC?
    @ObservationIgnored private var curlActive = false      // a curl is on screen
    @ObservationIgnored private var curlCommitting = false  // waiting for the web view to catch up
    @ObservationIgnored private var settleWork: DispatchWorkItem?

    // Book-wide page numbers: exact counts for chapters we have laid out, estimates for the rest.
    @ObservationIgnored private var chapterWeights: [Double] = []
    private var measuredPages: [Int: Int] = [:]
    @ObservationIgnored private var measuredWidth: CGFloat = 0
    @ObservationIgnored private var settleGen = 0

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
        renderer = PageRenderer(epub: epub, scheme: scheme)
        pageVC = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                      options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])
        container = ReaderContainerView(webView: webView, renderer: renderer.webView, curlView: pageVC.view)
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
        swipes = [left, right]

        // The page view controller's own pan drives the curl. Move it onto the container so it
        // works while the curl view is hidden; taps stay ours (center toggles the toolbars).
        pageVC.isDoubleSided = false
        pageVC.dataSource = self
        pageVC.delegate = self
        pageVC.view.isHidden = true
        for g in pageVC.gestureRecognizers {
            if g is UITapGestureRecognizer {
                g.isEnabled = false
            } else {
                container.addGestureRecognizer(g)
                curlPan = g
            }
        }

        installUserScripts()
        updateTurnMode()
        loadChapterWeights()
    }

    /// Text volume per chapter (CJK characters count 1, others 0.5) for page estimates.
    private func loadChapterWeights() {
        let files = epub.spine.map { bookFolder.appendingPathComponent($0.path) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let tag = try? NSRegularExpression(pattern: "<[^>]*>", options: [])
            let weights: [Double] = files.map { url in
                guard let data = try? Data(contentsOf: url), var text = String(data: data, encoding: .utf8) else { return 0 }
                if let body = text.range(of: "<body", options: .caseInsensitive) { text = String(text[body.lowerBound...]) }
                let stripped = tag?.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "") ?? text
                var w = 0.0
                for u in stripped.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(u) {
                    w += u.value >= 0x2E80 ? 1 : 0.5
                }
                return w
            }
            DispatchQueue.main.async { self?.chapterWeights = weights }
        }
    }

    /// (current page, total pages) across the whole book, or nil until we can estimate.
    var bookPages: (current: Int, total: Int)? {
        let n = epub.spine.count
        guard chapterWeights.count == n else { return nil }
        var known = measuredPages
        known[spineIndex] = pageCount
        var w = 0.0, p = 0
        for (i, c) in known where chapterWeights[i] > 300 {
            w += chapterWeights[i]; p += c
        }
        let perPage = p > 0 ? w / Double(p) : 0
        guard perPage > 0 else { return nil }
        func pages(_ i: Int) -> Int {
            if let c = known[i] { return c }
            return max(1, Int((chapterWeights[i] / perPage).rounded()))
        }
        let before = (0..<spineIndex).reduce(0) { $0 + pages($1) }
        let total = (0..<n).reduce(0) { $0 + pages($1) }
        return (before + page + 1, max(total, before + page + 1))
    }

    /// Curl uses the interactive page view controller; slide/none use discrete swipes.
    func updateTurnMode() {
        let curl = ReaderSettings.shared.pageTurn == .curl
        curlPan?.isEnabled = curl && !hasSelection
        swipes.forEach { $0.isEnabled = !curl }
        if curl { scheduleSettle() } else { dropNeighbors() }
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

    private func tapTurn(_ dir: TurnDirection) {
        if ReaderSettings.shared.pageTurn == .curl, !curlActive,
           let target = dir == .forward ? nextVC : prevVC {
            curlActive = true
            pageVC.view.isHidden = false
            pageVC.setViewControllers([target], direction: dir == .forward ? .forward : .reverse, animated: true) { [weak self] _ in
                self?.commitCurl(to: target)
            }
        } else if !curlActive {
            turn(dir)
        }
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
        renderer.install(css: currentCSS())
        appliedSignature = ReaderSettings.shared.signature
    }

    /// Re-apply typography after settings changed, keeping the reading position.
    func settingsChanged() {
        let sig = ReaderSettings.shared.signature
        guard sig != appliedSignature else { return }
        installUserScripts()
        dropNeighbors()
        measuredPages = [:]
        webView.backgroundColor = UIColor(ReaderSettings.shared.theme.bgColor)
        pageVC.view.backgroundColor = UIColor(ReaderSettings.shared.theme.bgColor)
        let css = ReaderJS.jsonString(currentCSS())
        webView.evaluateJavaScript("window.reader && reader.applyStyle(\(css))")
    }

    // MARK: - Interactive curl

    /// Queue page-count measurements for chapters not laid out yet (exact book page numbers).
    private func measureRemainingChapters() {
        let width = webView.bounds.width
        for i in epub.spine.indices where measuredPages[i] == nil && i != spineIndex {
            renderer.measure(spine: i) { [weak self] count in
                guard let self, self.webView.bounds.width == width else { return }
                self.measuredPages[i] = count
            }
        }
    }

    private func dropNeighbors() {
        settleGen += 1
        renderer.cancelAll()
        nextVC = nil
        prevVC = nil
    }

    /// After the page stops moving: snapshot it as the curl's current page and pre-render neighbours.
    private func scheduleSettle() {
        guard ReaderSettings.shared.pageTurn == .curl else { return }
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func settle() {
        guard ReaderSettings.shared.pageTurn == .curl, !curlActive, !curlCommitting else { return }
        dropNeighbors()
        let gen = settleGen
        let here = PagePos(spine: spineIndex, page: page, count: pageCount)
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self, gen == self.settleGen, let image else { return }
            let cur = PageImageVC(pos: here, image: image)
            self.currentVC = cur
            self.pageVC.setViewControllers([cur], direction: .forward, animated: false)

            let next: (Int, Int)? = here.page + 1 < here.count ? (here.spine, here.page + 1)
                : (here.spine + 1 < self.epub.spine.count ? (here.spine + 1, 0) : nil)
            let prev: (Int, Int)? = here.page > 0 ? (here.spine, here.page - 1)
                : (here.spine > 0 ? (here.spine - 1, -1) : nil)
            if let next {
                self.renderer.render(spine: next.0, page: next.1) { [weak self] img, pos in
                    guard let self, gen == self.settleGen, let img else { return }
                    self.nextVC = PageImageVC(pos: pos, image: img)
                    if self.measuredPages[pos.spine] != pos.count { self.measuredPages[pos.spine] = pos.count }
                }
            }
            if let prev {
                self.renderer.render(spine: prev.0, page: prev.1) { [weak self] img, pos in
                    guard let self, gen == self.settleGen, let img else { return }
                    self.prevVC = PageImageVC(pos: pos, image: img)
                    if self.measuredPages[pos.spine] != pos.count { self.measuredPages[pos.spine] = pos.count }
                }
            }
            self.measureRemainingChapters()
        }
    }

    /// Move the real web view to the page the curl landed on, then hide the curl layer.
    private func commitCurl(to vc: PageImageVC) {
        curlCommitting = true
        let pos = vc.pos
        if pos.spine == spineIndex {
            webView.evaluateJavaScript("reader.moved = true; reader.goTo(\(pos.page))")
        } else {
            open(spineIndex: pos.spine, progress: pos.count > 0 ? Double(pos.page) / Double(pos.count) : 0)
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.curlCommitting else { return }
            self.finishCurlCommit(chapterChanged: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
    }

    private func finishCurlCommit(chapterChanged: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (chapterChanged ? 0.15 : 0.05)) { [weak self] in
            guard let self, self.curlCommitting else { return }
            self.curlCommitting = false
            self.curlActive = false
            self.pageVC.view.isHidden = true
            self.scheduleSettle()
        }
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
        guard !curlCommitting, vc === currentVC else { return nil }
        return nextVC
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
        guard !curlCommitting, vc === currentVC else { return nil }
        return prevVC
    }

    func pageViewController(_ pvc: UIPageViewController, willTransitionTo pending: [UIViewController]) {
        curlActive = true
        settleWork?.cancel()
        pageVC.view.isHidden = false
    }

    func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        if completed, let vc = pvc.viewControllers?.first as? PageImageVC {
            commitCurl(to: vc)
        } else {
            curlActive = false
            pageVC.view.isHidden = true
        }
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
            if webView.bounds.width != measuredWidth { measuredWidth = webView.bounds.width; measuredPages = [:] }
            if measuredPages[spineIndex] != pageCount { measuredPages[spineIndex] = pageCount }
            let progress = Double(page) / Double(pageCount)
            onPositionChange?(spineIndex, progress)
            let isStart = body["start"] as? Bool ?? false
            if turnInFlight != nil { completeTurn(chapterChanged: isStart) }
            if curlCommitting { finishCurlCommit(chapterChanged: isStart) }
            scheduleSettle()
        case "nextChapter":
            nextChapter()
        case "prevChapter":
            prevChapter()
        case "tap":
            switch body["zone"] as? String {
            case "left": tapTurn(.backward)
            case "right": tapTurn(.forward)
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

    private let renderer: WKWebView
    private let curlView: UIView

    init(webView: WKWebView, renderer: WKWebView, curlView: UIView) {
        self.webView = webView
        self.renderer = renderer
        self.curlView = curlView
        super.init(frame: .zero)
        // Renderer sits underneath the visible web view, same size, so it lays out identically.
        for v in [renderer, webView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor),
                v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: topAnchor),
                v.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        snapshotView.contentMode = .scaleToFill
        snapshotView.isHidden = true
        snapshotView.isUserInteractionEnabled = true // swallow taps mid-animation
        addSubview(snapshotView)
        curlView.frame = bounds
        curlView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(curlView)
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
