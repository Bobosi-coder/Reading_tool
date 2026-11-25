import UIKit
import WebKit

/// A page position. `count` is the chapter's page count when the image was rendered.
struct PagePos: Equatable {
    let spine: Int
    let page: Int
    let count: Int
}

/// One page shown inside the UIPageViewController during a curl.
final class PageImageVC: UIViewController {
    let pos: PagePos
    let image: UIImage

    init(pos: PagePos, image: UIImage) {
        self.pos = pos
        self.image = image
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleToFill
        iv.backgroundColor = UIColor(ReaderSettings.shared.theme.bgColor)
        view = iv
    }
}

/// A hidden web view (behind the visible one) that renders neighbouring pages to images,
/// so the interactive page curl can show the next/previous page under the finger.
final class PageRenderer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    private let epub: EPUBBook
    private var loadedSpine: Int?
    private var onLoaded: (() -> Void)?

    private struct Job {
        let spine: Int
        let page: Int // -1 = last page
        let snapshot: Bool
        let completion: (UIImage?, PagePos) -> Void
    }
    private var queue: [Job] = []
    private var busy = false

    init(epub: EPUBBook, scheme: ReaderScheme) {
        self.epub = epub
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(scheme, forURLScheme: ReaderScheme.scheme)
        config.dataDetectorTypes = []
        config.userContentController = WKUserContentController()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(WeakMessageHandler(self), name: "reader")
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.isUserInteractionEnabled = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
    }

    /// Call whenever typography changes; forces chapters to reload with the new style.
    func install(css: String) {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: ReaderJS.startScript(css: css), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: ReaderJS.runtime, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView.backgroundColor = UIColor(ReaderSettings.shared.theme.bgColor)
        loadedSpine = nil
    }

    func cancelAll() {
        queue.removeAll()
    }

    /// Render a page image. Takes priority over page-count measurements.
    func render(spine: Int, page: Int, completion: @escaping (UIImage?, PagePos) -> Void) {
        guard epub.spine.indices.contains(spine) else { return }
        let firstMeasure = queue.firstIndex { !$0.snapshot } ?? queue.count
        queue.insert(Job(spine: spine, page: page, snapshot: true, completion: completion), at: firstMeasure)
        pump()
    }

    /// Lay out a chapter just to learn its page count (background, low priority).
    func measure(spine: Int, completion: @escaping (Int) -> Void) {
        guard epub.spine.indices.contains(spine) else { return }
        queue.append(Job(spine: spine, page: 0, snapshot: false) { _, pos in completion(pos.count) })
        pump()
    }

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let job = queue.removeFirst()
        let go: () -> Void = { [weak self] in self?.capture(job) }
        if loadedSpine == job.spine {
            go()
        } else {
            guard let url = ReaderScheme.url(forBookPath: epub.spine[job.spine].path) else { busy = false; pump(); return }
            loadedSpine = job.spine
            onLoaded = go
            webView.load(URLRequest(url: url))
        }
    }

    private func capture(_ job: Job) {
        let pageJS = job.page < 0 ? "reader.count - 1" : "\(job.page)"
        let js = """
        if (!reader.ready) reader.start({ progress: 0 });
        await document.fonts.ready;
        reader.relayout();
        reader.moved = true;
        reader.goTo(\(pageJS));
        await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
        return [reader.page, reader.count];
        """
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            var page = max(job.page, 0), count = 1
            if case .success(let value) = result, let arr = value as? [Int], arr.count == 2 {
                page = arr[0]; count = arr[1]
            }
            guard job.snapshot else {
                job.completion(nil, PagePos(spine: job.spine, page: page, count: count))
                self.busy = false
                self.pump()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                self.webView.takeSnapshot(with: nil) { image, _ in
                    job.completion(image, PagePos(spine: job.spine, page: page, count: count))
                    self.busy = false
                    self.pump()
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let next = onLoaded
        onLoaded = nil
        next?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadedSpine = nil
        busy = false
        onLoaded = nil
        pump()
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {}
}
