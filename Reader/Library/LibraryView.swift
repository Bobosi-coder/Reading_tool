import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Book.lastOpenedAt, order: .reverse), SortDescriptor(\Book.addedAt, order: .reverse)])
    private var books: [Book]

    @State private var importing = false
    @State private var errorMessage: String?
    @State private var openBook: Book?
    @State private var showSettings = false
    @State private var bookToDelete: Book?

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 24)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if books.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 28) {
                        ForEach(books) { book in
                            Button { openBook = book } label: { BookCell(book: book) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) { bookToDelete = book } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle("书库")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Label("导入", systemImage: "plus") }
                }
            }
        }
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("还没有书").font(.title3)
            Text("点右上角「导入」，从「文件」里选择 EPUB。\n也可以在「文件」App 里长按 EPUB → 共享 → 阅读。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("导入 EPUB") { importing = true }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
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

struct BookCell: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            Text(book.title).font(.subheadline.weight(.medium)).lineLimit(2)
            HStack {
                Text(book.author).lineLimit(1)
                Spacer()
                if book.totalProgress > 0 {
                    Text("\(Int(book.totalProgress * 100))%")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cover: some View {
        if let url = book.coverURL, let img = UIImage(contentsOfFile: url.path) {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
        } else {
            ZStack {
                LinearGradient(colors: [Color(hex: "#8a6f4d"), Color(hex: "#5b4632")], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(book.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(12)
            }
        }
    }
}
