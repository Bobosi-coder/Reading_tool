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

    @MainActor
    static func delete(_ book: Book, from context: ModelContext) {
        try? FileManager.default.removeItem(at: book.folderURL)
        context.delete(book)
        try? context.save()
    }
}
