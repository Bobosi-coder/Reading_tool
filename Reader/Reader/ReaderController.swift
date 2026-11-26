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

struct PageKey: Hashable {
    let spine: Int
    let page: Int // -1 = last page of the chapter (count not known yet)
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
    /// The page image the curl layer currently rests on.
    @ObservationIgnored private var currentVC: PageImageVC?
    /// Pre-rendered pages around the current one (two each way), so quick successive swipes always have a page.
    @ObservationIgnored private var pageCache: [PageKey: PageImageVC] = [:]
    @ObservationIgnored private var rendering: Set<PageKey> = []
    @ObservationIgnored private var cacheGen = 0
    @ObservationIgnored private var curlTransitioning = false // finger down / animation running
    @ObservationIgnored private var curlCommitting = false    // web view not yet on the page the curl shows
    @ObservationIgnored private var commitTarget: PagePos?
    @ObservationIgnored private var chapterLoading = false
    @ObservationIgnored private var lastCurlStart = Date.distantPast
    /// Turns asked for while a curl was still animating (+ forward, − backward); played as soon as it lands.
    @ObservationIgnored private var queuedTurns = 0
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
        for s in [left, right] {
            s.delegate = self
            webView.addGestureRecognizer(s)
        }
        swipes = [left, right]

        // The page view controller's own pan drives the curl. Move it onto the container so it
        // works while the curl view is hidden; taps stay ours (center toggles the toolbars).
        pageVC.isDoubleSided = false
        pageVC.dataSource = self
        pageVC.delegate = self
        pageVC.view.isHidden = true
        // Touches pass through to the web view (taps, selection); the pan lives on the container.
        pageVC.view.isUserInteractionEnabled = false
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
        // In curl mode the swipes are a fallback for when the curl could not start (page not ready yet).
        swipes.forEach { $0.isEnabled = true }
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
        chapterLoading = true
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
        guard ReaderSettings.shared.pageTurn == .curl else { turn(dir); return }
        guard !curlTransitioning else {
            queuedTurns = max(-3, min(3, queuedTurns + (dir == .forward ? 1 : -1)))
            return
        }
        if let cur = shownVC, let target = neighbor(of: cur, forward: dir == .forward) {
            curlTransitioning = true
            settleWork?.cancel()
            pageVC.view.isHidden = false
            pageVC.setViewControllers([target], direction: dir == .forward ? .forward : .reverse, animated: true) { [weak self] _ in
                guard let self else { return }
                self.curlTransitioning = false
                self.landed(on: target)
            }
        } else if !curlCommitting && currentVC?.pos.spine == spineIndex {
            // Neighbour not rendered yet: animate from a live snapshot instead.
            turn(dir)
        } else {
            // Web view still catching up and the page isn't rendered yet: play it once it is.
            queuedTurns = max(-3, min(3, queuedTurns + (dir == .forward ? 1 : -1)))
        }
    }

    private func playQueuedTurn() {
        guard queuedTurns != 0, !curlTransitioning, let cur = shownVC else { return }
        let dir: TurnDirection = queuedTurns > 0 ? .forward : .backward
        guard neighbor(of: cur, forward: dir == .forward) != nil else {
            // Nothing that way (book edge) and nothing being rendered: give up.
            if neighborKey(cur.pos, forward: dir == .forward) == nil || rendering.isEmpty { queuedTurns = 0 }
            return
        }
        queuedTurns += queuedTurns > 0 ? -1 : 1
        tapTurn(dir)
    }

    @objc private func swipeLeft() { swiped(.forward) }
    @objc private func swipeRight() { swiped(.backward) }

    private func swiped(_ dir: TurnDirection) {
        guard ReaderSettings.shared.pageTurn == .curl else { turn(dir); return }
        // The interactive curl normally handles the gesture; only step in if it didn't start
        // (page not ready, or the previous curl is still animating — then it's queued).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, !self.hasSelection,
                  Date().timeIntervalSince(self.lastCurlStart) > 0.2 else { return }
            self.tapTurn(dir)
        }
    }

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
        currentVC = nil
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
        cacheGen += 1
        renderer.cancelAll()
        pageCache = [:]
        rendering = []
    }

    /// The page image under the curl layer, if it matches what the reader should be seeing.
    private var shownVC: PageImageVC? {
        guard let cur = currentVC, pageVC.viewControllers?.first === cur else { return nil }
        let want = curlCommitting ? commitTarget : PagePos(spine: spineIndex, page: page, count: pageCount)
        guard let want, cur.pos.spine == want.spine, cur.pos.page == want.page else { return nil }
        return cur
    }

    private func neighborKey(_ p: PagePos, forward: Bool) -> PageKey? {
        if forward {
            if p.page + 1 < p.count { return PageKey(spine: p.spine, page: p.page + 1) }
            return p.spine + 1 < epub.spine.count ? PageKey(spine: p.spine + 1, page: 0) : nil
        }
        if p.page > 0 { return PageKey(spine: p.spine, page: p.page - 1) }
        guard p.spine > 0 else { return nil }
        if let c = measuredPages[p.spine - 1] { return PageKey(spine: p.spine - 1, page: c - 1) }
        return PageKey(spine: p.spine - 1, page: -1) // last page, count unknown yet
    }

    private func cached(_ k: PageKey) -> PageImageVC? {
        if k.page >= 0 { return pageCache[k] }
        return pageCache.values.first { $0.pos.spine == k.spine && $0.pos.page == $0.pos.count - 1 }
    }

    private func neighbor(of vc: PageImageVC, forward: Bool) -> PageImageVC? {
        neighborKey(vc.pos, forward: forward).flatMap(cached)
    }

    /// Keep two rendered pages on each side of the current one; drop the rest.
    private func refill() {
        guard ReaderSettings.shared.pageTurn == .curl, let anchor = currentVC else { return }
        var keep: Set<PageKey> = [PageKey(spine: anchor.pos.spine, page: anchor.pos.page)]
        for forward in [true, false] {
            var pos = anchor.pos
            for _ in 0..<2 {
                guard let k = neighborKey(pos, forward: forward) else { break }
                if let hit = cached(k) {
                    keep.insert(PageKey(spine: hit.pos.spine, page: hit.pos.page))
                    pos = hit.pos
                    continue
                }
                if !rendering.contains(k) {
                    rendering.insert(k)
                    let gen = cacheGen
                    renderer.render(spine: k.spine, page: k.page) { [weak self] img, rpos in
                        guard let self, gen == self.cacheGen else { return }
                        self.rendering.remove(k)
                        if self.measuredPages[rpos.spine] != rpos.count { self.measuredPages[rpos.spine] = rpos.count }
                        if let img {
                            self.pageCache[PageKey(spine: rpos.spine, page: rpos.page)] = PageImageVC(pos: rpos, image: img)
                        }
                        self.refill()
                        self.playQueuedTurn()
                    }
                }
                break
            }
        }
        for k in pageCache.keys where !keep.contains(k) && !(rendering.contains(k)) {
            if let vc = pageCache[k], vc === currentVC { continue }
            let near = keep.contains { $0.spine == k.spine && abs($0.page - k.page) <= 2 }
            if !near { pageCache[k] = nil }
        }
    }

    /// After the page stops moving: make sure the curl layer rests on an image of it, then pre-render neighbours.
    private func scheduleSettle() {
        guard ReaderSettings.shared.pageTurn == .curl else { return }
        settleWork?.cancel()
        let here = PagePos(spine: spineIndex, page: page, count: pageCount)
        if let cur = currentVC, cur.pos == here, pageVC.viewControllers?.first === cur {
            refill()
            measureRemainingChapters()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func settle() {
        guard ReaderSettings.shared.pageTurn == .curl, !curlTransitioning, !curlCommitting else { return }
        settleGen += 1
        let gen = settleGen
        let here = PagePos(spine: spineIndex, page: page, count: pageCount)
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self, gen == self.settleGen, !self.curlTransitioning, !self.curlCommitting, let image else { return }
            let cur = PageImageVC(pos: here, image: image)
            self.currentVC = cur
            self.pageCache[PageKey(spine: here.spine, page: here.page)] = cur
            self.pageVC.setViewControllers([cur], direction: .forward, animated: false)
            self.refill()
            self.measureRemainingChapters()
        }
    }

    /// A curl finished on `vc`: it becomes the current page right away, and the web view follows.
    private func landed(on vc: PageImageVC) {
        currentVC = vc
        pageCache[PageKey(spine: vc.pos.spine, page: vc.pos.page)] = vc
        commitTarget = vc.pos
        curlCommitting = true
        refill()
        driveWebViewToTarget()
        if queuedTurns != 0 {
            DispatchQueue.main.async { [weak self] in self?.playQueuedTurn() }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.curlCommitting, self.commitTarget == vc.pos else { return }
            self.finishCurlCommit(chapterChanged: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
    }

    /// Move the real web view to the page the curl shows (the latest one if several curls queued up).
    private func driveWebViewToTarget() {
        guard let t = commitTarget else { return }
        let progress = t.count > 0 ? Double(t.page) / Double(t.count) : 0
        if t.spine != spineIndex {
            open(spineIndex: t.spine, progress: progress)
        } else if chapterLoading {
            pendingTarget = (progress, nil)
        } else {
            webView.evaluateJavaScript("reader.moved = true; reader.goTo(\(t.page))")
        }
    }

    private func finishCurlCommit(chapterChanged: Bool) {
        let target = commitTarget
        DispatchQueue.main.asyncAfter(deadline: .now() + (chapterChanged ? 0.15 : 0.05)) { [weak self] in
            guard let self, self.curlCommitting, self.commitTarget == target else { return }
            self.curlCommitting = false
            self.commitTarget = nil
            if !self.curlTransitioning { self.pageVC.view.isHidden = true }
            self.scheduleSettle()
        }
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
        guard let vc = vc as? PageImageVC, vc === shownVC else { return nil }
        return neighbor(of: vc, forward: true)
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
        guard let vc = vc as? PageImageVC, vc === shownVC else { return nil }
        return neighbor(of: vc, forward: false)
    }

    func pageViewController(_ pvc: UIPageViewController, willTransitionTo pending: [UIViewController]) {
        curlTransitioning = true
        lastCurlStart = Date()
        settleWork?.cancel()
        pageVC.view.isHidden = false
    }

    func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        curlTransitioning = false
        if completed, let vc = pvc.viewControllers?.first as? PageImageVC {
            landed(on: vc)
        } else {
            queuedTurns = 0
            if !curlCommitting { pageVC.view.isHidden = true }
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

// MARK: - Gestures

extension ReaderController: UIGestureRecognizerDelegate {
    /// Let the fallback swipes run alongside the curl pan and the web view's own recognizers.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
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
            chapterLoading = false
            if webView.bounds.width != measuredWidth {
                measuredWidth = webView.bounds.width
                measuredPages = [:]
                dropNeighbors()
                currentVC = nil
            }
            if measuredPages[spineIndex] != pageCount { measuredPages[spineIndex] = pageCount }
            let progress = Double(page) / Double(pageCount)
            onPositionChange?(spineIndex, progress)
            let isStart = body["start"] as? Bool ?? false
            if turnInFlight != nil { completeTurn(chapterChanged: isStart) }
            if curlCommitting, let t = commitTarget {
                if t.spine == spineIndex && t.page == page || t.page >= pageCount {
                    finishCurlCommit(chapterChanged: isStart)
                } else if t.spine != spineIndex || isStart {
                    driveWebViewToTarget() // a newer curl landed elsewhere while this one was loading
                }
            }
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

