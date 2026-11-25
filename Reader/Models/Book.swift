import Foundation
import SwiftData

@Model
final class Book {
    @Attribute(.unique) var id: UUID
    var title: String
    var author: String
    /// Folder name under Documents/Books/<folder> holding the unzipped EPUB.
    var folder: String
    /// Cover image path relative to the book folder (may be empty).
    var coverPath: String
    var addedAt: Date
    var lastOpenedAt: Date?
    /// Reading position: spine index + progress (0...1) inside that chapter.
    var spineIndex: Int
    var chapterProgress: Double
    /// Rough whole-book progress for display.
    var totalProgress: Double

    init(title: String, author: String, folder: String, coverPath: String) {
        self.id = UUID()
        self.title = title
        self.author = author
        self.folder = folder
        self.coverPath = coverPath
        self.addedAt = .now
        self.lastOpenedAt = nil
        self.spineIndex = 0
        self.chapterProgress = 0
        self.totalProgress = 0
    }

    var folderURL: URL { BookStore.booksDirectory.appendingPathComponent(folder, isDirectory: true) }

    var coverURL: URL? {
        coverPath.isEmpty ? nil : folderURL.appendingPathComponent(coverPath)
    }
}
