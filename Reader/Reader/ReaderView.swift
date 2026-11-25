import SwiftUI
import SwiftData

struct ReaderView: View {
    let book: Book

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ReaderSettings.self) private var settings

    @State private var controller: ReaderController?
    @State private var loadError: String?
    @State private var showTOC = false
    @State private var showStyle = false
    @State private var showAI = false

    var body: some View {
        ZStack {
            settings.theme.bgColor.ignoresSafeArea()

            if let controller {
                readerBody(controller)
            } else if let loadError {
                VStack(spacing: 12) {
                    Text(loadError).foregroundStyle(settings.theme.fgColor)
                    Button("返回") { dismiss() }
                }
            } else {
                ProgressView()
            }
        }
        .preferredColorScheme(settings.theme.isDark ? .dark : .light)
        .statusBarHidden(!(controller?.showChrome ?? true))
        .task { load() }
        .onChange(of: settings.signature) { controller?.settingsChanged() }
    }

    @ViewBuilder
    private func readerBody(_ c: ReaderController) -> some View {
        ZStack {
            ReaderWebView(controller: c)
                .ignoresSafeArea(edges: .bottom)

            // Running header / footer (always visible, subtle).
            VStack {
                Text(c.chapterTitle.isEmpty ? book.title : c.chapterTitle)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 40)
                    .padding(.top, 14)
                Spacer()
                HStack {
                    Text("\(c.page + 1) / \(c.pageCount)")
                    Spacer()
                    Text("\(Int(c.totalProgress * 100))%")
                }
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 40)
                .padding(.bottom, 10)
            }
            .foregroundStyle(settings.theme.fgColor.opacity(0.45))
            .allowsHitTesting(false)

            if c.showChrome { chrome(c) }

            // Floating shortcut when text is selected (in case the edit menu is dismissed).
            if c.hasSelection && !showAI {
                VStack {
                    Spacer()
                    Button {
                        c.requestAI(.ask)
                    } label: {
                        Label("问 AI", systemImage: "sparkles")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .padding(.bottom, 36)
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showTOC) {
            TOCView(epub: c.epub, currentIndex: c.spineIndex) { entry in
                c.open(tocEntry: entry)
                showTOC = false
                c.showChrome = false
            }
        }
        .inspector(isPresented: $showAI) {
            AskAIView(bookTitle: book.title, author: book.author, payload: c.askPayload)
                .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
        }
        .onChange(of: c.askPayload?.id) {
            if c.askPayload != nil { showAI = true }
        }
    }

    @ViewBuilder
    private func chrome(_ c: ReaderController) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                Button { dismiss() } label: { Image(systemName: "chevron.backward") }
                Text(book.title).font(.headline).lineLimit(1)
                Spacer()
                Button { showTOC = true } label: { Image(systemName: "list.bullet") }
                Button { showStyle.toggle() } label: { Image(systemName: "textformat.size") }
                    .popover(isPresented: $showStyle) {
                        TypographyView()
                            .frame(width: 380, height: 620)
                            .presentationCompactAdaptation(.popover)
                    }
                Button { showAI.toggle() } label: { Image(systemName: "sparkles") }
            }
            .font(.title3)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)

            Spacer()

            HStack(spacing: 16) {
                Button { c.prevChapter(atEnd: false) } label: { Image(systemName: "backward.end") }
                    .disabled(c.spineIndex == 0)
                ProgressView(value: c.totalProgress)
                Button { c.nextChapter() } label: { Image(systemName: "forward.end") }
                    .disabled(c.spineIndex >= c.epub.spine.count - 1)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.bar)
        }
        .transition(.opacity)
    }

    private func load() {
        guard controller == nil else { return }
        do {
            let epub = try EPUBParser.parse(folder: book.folderURL)
            let c = ReaderController(epub: epub, bookFolder: book.folderURL)
            c.onPositionChange = { [book] index, progress in
                book.spineIndex = index
                book.chapterProgress = progress
                book.totalProgress = c.totalProgress
                book.lastOpenedAt = .now
            }
            book.lastOpenedAt = .now
            controller = c
            c.open(spineIndex: min(book.spineIndex, epub.spine.count - 1), progress: book.chapterProgress)
        } catch {
            loadError = error.localizedDescription
        }
    }
}

struct TOCView: View {
    let epub: EPUBBook
    let currentIndex: Int
    let onSelect: (TOCEntry) -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(epub.toc) { entry in
                    let isCurrent = epub.spineIndex(forPath: entry.path) == currentIndex
                    Button { onSelect(entry) } label: {
                        Text(entry.title)
                            .padding(.leading, CGFloat(entry.level) * 18)
                            .fontWeight(isCurrent ? .semibold : .regular)
                            .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    }
                    .id(entry.id)
                }
                .onAppear {
                    if let e = epub.toc.last(where: { (epub.spineIndex(forPath: $0.path) ?? .max) <= currentIndex }) {
                        proxy.scrollTo(e.id, anchor: .center)
                    }
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
