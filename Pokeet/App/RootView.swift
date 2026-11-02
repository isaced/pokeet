import SwiftUI

struct RootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var usesSplitLayout: Bool {
        horizontalSizeClass == .regular || verticalSizeClass == .compact
    }

    var body: some View {
        if usesSplitLayout {
            SplitRootView()
        } else {
            NavigationStack {
                ProjectsView()
            }
        }
    }
}
