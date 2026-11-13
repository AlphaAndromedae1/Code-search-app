import SwiftUI

enum AppTab: Hashable {
    case library
    case search
    case compare
    case saved
    case updates
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
    var compareRequest: CompareRequest?

    func openInCompare(left: PageRef?, right: PageRef?) {
        compareRequest = CompareRequest(left: left, right: right)
        selectedTab = .compare
    }
}
