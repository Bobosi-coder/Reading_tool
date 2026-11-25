import SwiftUI
import SwiftData

@main
struct ReaderApp: App {
    @State private var settings = ReaderSettings.shared

    init() {
        FontManager.shared.registerAllForUI()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(settings)
        }
        .modelContainer(for: Book.self)
    }
}
