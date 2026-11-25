import SwiftUI
import SwiftData

struct ReaderView: View {
    let book: Book

    @Environment(\.dismiss) private var dismiss
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
                VStack(spacing: 14) {
                    Text(loadError).foregroundStyle(settings.theme.fgColor)
                    Button("返回") { dismiss() }
                }
            } else {
                ProgressView()
            }
        }
        .preferredColorScheme(settings.theme.isDark ? .dark : .light)
        // Keep the status bar hidden so the page never resizes (and re-flows) when toolbars appear.
        .statusBarHidden(true)
        .task { load() }
        .onChange(of: settings.signature) { controller?.settingsChanged() }
        .onChange(of: settings.pageTurn) { controller?.updateTurnMode() }
    }

    @ViewBuilder
    private func readerBody(_ c: ReaderController) -> some View {
        let fg = settings.theme.fgColor
        ZStack {
            ReaderWebView(controller: c)
                .ignoresSafeArea()

            // Running header / footer.
            VStack {
                Text(c.chapterTitle.isEmpty ? book.title : c.chapterTitle)
                    .font(DS.serif(12))
                    .tracking(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, 60)
                    .padding(.top, 14)
                Spacer()
                HStack {
                    if let bp = c.bookPages {
                        Text("\(bp.current) / \(bp.total)")
                    } else {
                        Text("\(c.page + 1) / \(c.pageCount)")
                    }
                    Spacer()
                    Text(c.pageCount - c.page - 1 > 0 ? "本章剩 \(c.pageCount - c.page - 1) 页" : "本章最后一页")
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .padding(.horizontal, 40)
                .padding(.bottom, 10)
            }
            .foregroundStyle(fg.opacity(0.4))
            .allowsHitTesting(false)
            .opacity(c.showChrome ? 0 : 1)

            if c.showChrome { chrome(c) }

            if c.hasSelection && !showAI { selectionBar(c) }

            if showAI { aiPanel(c) }
        }
        .animation(.easeInOut(duration: 0.22), value: c.showChrome)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: c.hasSelection)
        .sheet(isPresented: $showTOC) {
            TOCView(epub: c.epub, bookTitle: book.title, currentIndex: c.spineIndex) { entry in
                c.open(tocEntry: entry)
                showTOC = false
                c.showChrome = false
            }
            .presentationDetents([.large])
        }
        .onChange(of: c.askPayload?.id) {
            if c.askPayload != nil {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) { showAI = true }
            }
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private func chrome(_ c: ReaderController) -> some View {
        VStack {
            HStack(spacing: 12) {
                GlassIconButton(systemName: "chevron.backward") { dismiss() }
                Spacer()
                VStack(spacing: 2) {
                    Text(book.title).font(DS.serif(15, .semibold)).lineLimit(1)
                    if !c.chapterTitle.isEmpty {
                        Text(c.chapterTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                HStack(spacing: 4) {
                    toolButton("list.bullet") { showTOC = true }
                    toolButton("textformat.size") { showStyle.toggle() }
                        .popover(isPresented: $showStyle, arrowEdge: .top) {
                            TypographyView()
                                .frame(width: 400, height: 640)
                                .presentationCompactAdaptation(.popover)
                        }
                    toolButton("sparkles") {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) { showAI.toggle() }
                    }
                }
                .padding(4)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Spacer()

            HStack(spacing: 14) {
                toolButton("chevron.left.2") { c.prevChapter(atEnd: false) }
                    .disabled(c.spineIndex == 0)
                VStack(spacing: 6) {
                    ThinProgress(value: c.totalProgress, height: 3)
                    HStack {
                        Text("第 \(c.spineIndex + 1) / \(c.epub.spine.count) 节")
                        Spacer()
                        Text("本章剩 \(max(0, c.pageCount - c.page - 1)) 页")
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                toolButton("chevron.right.2") { c.nextChapter() }
                    .disabled(c.spineIndex >= c.epub.spine.count - 1)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .foregroundStyle(DS.ink)
        .transition(.opacity)
    }

    private func toolButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: - Selection actions

    private func selectionBar(_ c: ReaderController) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 0) {
                selectionButton(.ask, c)
                Rectangle().fill(DS.hairline).frame(width: 1, height: 22)
                selectionButton(.translateExplain, c)
            }
            .padding(.horizontal, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(DS.hairline.opacity(0.7), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
            .padding(.bottom, 40)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func selectionButton(_ action: AIQuickAction, _ c: ReaderController) -> some View {
        Button { c.requestAI(action) } label: {
            Label(action.title, systemImage: action.symbol)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18).padding(.vertical, 12)
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: - AI panel

    private func aiPanel(_ c: ReaderController) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Color.black.opacity(0.12)
                    .contentShape(Rectangle())
                    .onTapGesture { closeAI() }
                AskAIView(bookTitle: book.title, author: book.author, payload: c.askPayload, onClose: closeAI)
                    .frame(width: min(460, max(360, geo.size.width * 0.56)))
                    .background(DS.paper)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 28, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 24, x: -4)
            }
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .transition(.move(edge: .trailing))
    }

    private func closeAI() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { showAI = false }
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
    let bookTitle: String
    let currentIndex: Int
    let onSelect: (TOCEntry) -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(epub.toc) { entry in
                    let isCurrent = epub.spineIndex(forPath: entry.path) == currentIndex && entry.level == 0
                    Button { onSelect(entry) } label: {
                        HStack(spacing: 10) {
                            if isCurrent {
                                Capsule().fill(Color.accentColor).frame(width: 3, height: 18)
                            }
                            Text(entry.title)
                                .font(entry.level == 0 ? DS.serif(17, isCurrent ? .semibold : .regular) : .subheadline)
                                .foregroundStyle(isCurrent ? Color.accentColor : (entry.level == 0 ? DS.ink : DS.inkSoft))
                        }
                        .padding(.leading, CGFloat(entry.level) * 20)
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.clear)
                    .id(entry.id)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(DS.paper)
                .onAppear {
                    if let e = epub.toc.last(where: { (epub.spineIndex(forPath: $0.path) ?? .max) <= currentIndex }) {
                        proxy.scrollTo(e.id, anchor: .center)
                    }
                }
            }
            .navigationTitle(bookTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
