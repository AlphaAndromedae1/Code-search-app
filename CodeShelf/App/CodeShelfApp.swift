import SwiftUI

@main
struct CodeShelfApp: App {
    @State private var store = LibraryStore()
    @State private var router = AppRouter()
    @State private var updates = UpdatesStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(router)
                .environment(updates)
                .onOpenURL { url in
                    // "Open in CodeShelf" / share sheet from Files, Mail, Safari, etc.
                    guard url.isFileURL else { return }
                    router.selectedTab = .library
                    Task { await store.importPDFs(from: [url]) }
                }
        }
    }
}
