import Foundation
import SwiftData
import ZIPFoundation

enum BookStore {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var booksDirectory: URL {
        let url = documents.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Unzip an EPUB into the library and insert a Book record.
    @MainActor
    static func importEPUB(from source: URL, into context: ModelContext) throws -> Book {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let folderName = UUID().uuidString
        let dest = booksDirectory.appendingPathComponent(folderName, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        do {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue {
                // Some apps hand over an unpacked .epub package directory.
                for item in try fm.contentsOfDirectory(atPath: source.path) {
                    try fm.copyItem(at: source.appendingPathComponent(item), to: dest.appendingPathComponent(item))
                }
            } else {
                try fm.unzipItem(at: source, to: dest)
            }
            let epub = try EPUBParser.parse(folder: dest)
            let book = Book(title: epub.title, author: epub.author, folder: folderName, coverPath: epub.coverPath)
            context.insert(book)
            try? context.save()
            return book
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
    }

    /// Import any .epub / font files dropped into Documents (e.g. via Finder file sharing),
    /// then remove the originals. Returns error messages for files that failed.
    @MainActor
    static func importDroppedFiles(into context: ModelContext) -> [String] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
        var errors: [String] = []
        for url in items {
            let ext = url.pathExtension.lowercased()
            // Skip files still being copied in (modified in the last moment); the watcher retries.
            if let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               Date().timeIntervalSince(modified) < 1.5 { continue }
            do {
                if ext == "epub" {
                    _ = try importEPUB(from: url, into: context)
                } else if FontManager.allowedExtensions.contains(ext) {
                    _ = try FontManager.shared.importFont(from: url)
                } else {
                    continue
                }
                try? fm.removeItem(at: url)
            } catch {
                errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return errors
    }

    @MainActor
    static func delete(_ book: Book, from context: ModelContext) {
        try? FileManager.default.removeItem(at: book.folderURL)
        context.delete(book)
        try? context.save()
    }
}

/// Watches the Documents folder (Finder / Files drops) while the app is open.
final class DocumentsWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let fd = open(BookStore.documents.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        src.setEventHandler { [weak self] in self?.changed() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }

    /// Debounced; scans again a little later so a file that was mid-copy gets picked up.
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.onChange() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}
