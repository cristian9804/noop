import SwiftUI

/// Root — the sidebar shell, with the first-run onboarding/pairing wizard overlaid until complete.
struct ContentView: View {
    @AppStorage("noop.onboarded") private var onboarded = false
    var body: some View {
        ZStack {
            RootView()
            if !onboarded {
                OnboardingWizard(onFinished: { onboarded = true })
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: onboarded)
    }
}
