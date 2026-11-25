import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Book.addedAt, order: .reverse)])
    private var books: [Book]

    @State private var importing = false
    @State private var errorMessage: String?
    @State private var openBook: Book?
    @State private var showSettings = false
    @State private var bookToDelete: Book?

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 160), spacing: 28, alignment: .top)]

    private var currentBook: Book? {
        books.filter { $0.lastOpenedAt != nil }.max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                header

                if books.isEmpty {
                    emptyState
                } else {
                    if let currentBook {
                        ContinueReadingCard(book: currentBook) { openBook = currentBook }
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("书库").font(DS.serif(22, .semibold))
                            Text("\(books.count) 本").font(.subheadline).foregroundStyle(DS.inkSoft)
                            Spacer()
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 34) {
                            ForEach(books) { book in
                                Button { openBook = book } label: { BookCell(book: book) }
                                    .buttonStyle(PressableStyle())
                                    .contextMenu {
                                        Button(role: .destructive) { bookToDelete = book } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 60)
            .foregroundStyle(DS.ink)
        }
        .background(DS.paper.ignoresSafeArea())
        .fileImporter(isPresented: $importing, allowedContentTypes: [.epub], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): urls.forEach(importBook)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .task { scanDropped() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            scanDropped()
        }
        .onOpenURL { url in
            if url.pathExtension.lowercased() == "epub" { importBook(url) }
        }
        .fullScreenCover(item: $openBook) { book in
            ReaderView(book: book)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert("导入失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("删除这本书？", isPresented: Binding(get: { bookToDelete != nil }, set: { if !$0 { bookToDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let b = bookToDelete { BookStore.delete(b, from: context) }
                bookToDelete = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.greeting)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(DS.inkSoft)
                Text("Dive in")
                    .font(DS.serif(40, .bold))
            }
            Spacer()
            HStack(spacing: 12) {
                GlassIconButton(systemName: "plus") { importing = true }
                GlassIconButton(systemName: "gearshape") { showSettings = true }
            }
        }
    }

    static var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        let part = switch h {
        case 5..<11: "早上好"
        case 11..<14: "中午好"
        case 14..<18: "下午好"
        case 18..<23: "晚上好"
        default: "夜深了"
        }
        let date = Date.now.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_CN")))
        return "\(date) · \(part)"
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("书架还空着").font(DS.serif(24, .semibold))
            Text("导入一本 EPUB，开始阅读。\n也可以在 Mac 的「访达」里把书拖进这个 App。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(DS.inkSoft)
            Button { importing = true } label: {
                Label("导入 EPUB", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(PressableStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 140)
    }

    private func scanDropped() {
        let errors = BookStore.importDroppedFiles(into: context)
        if !errors.isEmpty { errorMessage = errors.joined(separator: "\n") }
    }

    private func importBook(_ url: URL) {
        do {
            _ = try BookStore.importEPUB(from: url, into: context)
        } catch {
            errorMessage = "\(url.lastPathComponent)：\(error.localizedDescription)"
        }
    }
}

struct ContinueReadingCard: View {
    let book: Book
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .bottom, spacing: 24) {
                BookCoverView(title: book.title, author: book.author, coverURL: book.coverURL)
                    .frame(width: 112)
                VStack(alignment: .leading, spacing: 10) {
                    Text("继续阅读")
                        .font(.caption.weight(.semibold))
                        .tracking(2)
                        .foregroundStyle(Color.accentColor)
                    Text(book.title)
                        .font(DS.serif(26, .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !book.author.isEmpty {
                        Text(book.author).font(.subheadline).foregroundStyle(DS.inkSoft).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 12) {
                        ThinProgress(value: book.totalProgress)
                        Text("\(Int(book.totalProgress * 100))%")
                            .font(.footnote.monospacedDigit().weight(.medium))
                            .foregroundStyle(DS.inkSoft)
                    }
                    HStack {
                        Spacer()
                        Label("打开", systemImage: "book")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(DS.card)
                    .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
            )
            .foregroundStyle(DS.ink)
        }
        .buttonStyle(PressableStyle())
    }
}

struct BookCell: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BookCoverView(title: book.title, author: book.author, coverURL: book.coverURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(DS.serif(15, .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(DS.ink)
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(DS.inkSoft)
            }
        }
    }

    private var progressText: String {
        if book.lastOpenedAt == nil { return "未读" }
        if book.totalProgress >= 0.99 { return "已读完" }
        return "已读 \(Int(book.totalProgress * 100))%"
    }
}
