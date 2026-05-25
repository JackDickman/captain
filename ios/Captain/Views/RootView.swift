import SwiftUI

/// Switches between first-session onboarding and the home screen based on
/// whether AppState already has a captured first session.
struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if let session = appState.firstSession {
                HomeView(session: session)
            } else {
                FirstSessionView()
            }
        }
        .animation(.easeInOut(duration: 0.4), value: appState.firstSession)
    }
}
