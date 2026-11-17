import SwiftUI

enum AppTab: Hashable {
    case library
    case search
    case tools
    case saved
    case updates
}

/// Screens inside the Tools tab.
enum ToolRoute: Hashable {
    case pipeSizing
    case csstSizing
    case fuelPrices
    case compare
}

struct CompareRequest: Equatable {
    let id = UUID()
    var left: PageRef?
    var right: PageRef?
}

/// Cross-tab navigation (e.g. "Open in Compare" from the reader).
@MainActor
@Observable
final class AppRouter {
    var selectedTab: AppTab = .library
    var toolsPath: [ToolRoute] = []
    var compareRequest: CompareRequest?

    func openInCompare(left: PageRef?, right: PageRef?) {
        compareRequest = CompareRequest(left: left, right: right)
        toolsPath = [.compare]
        selectedTab = .tools
    }
}
