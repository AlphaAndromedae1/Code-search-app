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
                .task { await importLaunchArgumentFiles() }
        }
    }

    /// Debug builds only: `-importOnLaunch "/path/a.pdf|/path/b.pdf"` imports files at launch.
    /// Used by the CI simulator smoke test; does nothing in the release .ipa.
    @MainActor
    private func importLaunchArgumentFiles() async {
        #if DEBUG
        guard let paths = UserDefaults.standard.string(forKey: "importOnLaunch"), !paths.isEmpty else { return }
        let urls = paths.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
        await store.importPDFs(from: urls)
        #endif
    }
}
