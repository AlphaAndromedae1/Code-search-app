import SwiftUI

struct RootView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(UpdatesStore.self) private var updates
    @Environment(EquipmentLibrary.self) private var equipment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(AppTab.library)

            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppTab.search)

            CompareView()
                .tabItem { Label("Compare", systemImage: "rectangle.split.2x1") }
                .tag(AppTab.compare)

            SavedView()
                .tabItem { Label("Saved", systemImage: "bookmark") }
                .tag(AppTab.saved)

            UpdatesView()
                .tabItem { Label("Updates", systemImage: "megaphone") }
                .tag(AppTab.updates)
                .badge(updates.items.count)
        }
        .overlay(alignment: .top) {
            if store.importsInFlight > 0 {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Importing…")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: store.importsInFlight)
        .alert("CodeShelf", isPresented: alertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alertMessage ?? "")
        }
        .task {
            await Notifier.requestPermissionIfNeeded()
            await runAutomaticTasks()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await store.scanDocumentsFolder() }
                Task { await runAutomaticTasks() }
            case .background:
                store.saveNow()
                BackgroundRefresh.schedule()
            default:
                store.saveNow()
            }
        }
    }

    /// New TSSA / CSA / e-Laws items and newer manufacturer instructions, checked when the app opens.
    private func runAutomaticTasks() async {
        let terms = store.libraryTerms
        let updates = self.updates
        // Run the bulletin check alongside the downloads instead of waiting for it.
        Task { await updates.autoCheckIfDue(libraryTerms: terms) }
        let changed = await equipment.syncIfDue(store: store)
        if !changed.isEmpty {
            await Notifier.post(
                title: "\(changed.count) installation instruction\(changed.count == 1 ? "" : "s") downloaded or updated",
                body: changed.prefix(3).joined(separator: "\n")
            )
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )
    }
}
