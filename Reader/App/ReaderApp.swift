import SwiftUI
import SwiftData

@main
struct ReaderApp: App {
    @State private var settings = ReaderSettings.shared

    init() {
        FontManager.shared.registerAllForUI()
        // A previously chosen font may have been deleted; fall back to the defaults.
        let s = ReaderSettings.shared, fonts = FontManager.shared
        if !s.latinFont.isEmpty && !fonts.isAvailable(s.latinFont) { s.latinFont = ReaderSettings.defaultLatin }
        if !s.cjkFont.isEmpty && !fonts.isAvailable(s.cjkFont) { s.cjkFont = ReaderSettings.defaultCJK }
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(settings)
        }
        .modelContainer(for: Book.self)
    }
}
