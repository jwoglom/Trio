import SwiftUI
import WatchKit

struct AcknowledgementPendingView: View {
    @Binding var navigationPath: NavigationPath
    let state: WatchState
    @Binding var shouldNavigateToRoot: Bool

    var trioBackgroundColor = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    var statusIcon: some View {
        switch state.acknowledgementStatus {
        case .pending:
            return Image(systemName: "progress.indicator").foregroundStyle(Color.secondary)
        case .success:
            return Image(systemName: "checkmark.circle").foregroundStyle(Color.loopGreen)
        case .failure:
            return Image(systemName: "xmark").foregroundStyle(Color.loopRed)
        }
    }

    var body: some View {
        Group {
            if let refusedBolus = state.refusedBolus {
                refusedBolusView(refusedBolus)
            } else {
                acknowledgmentView
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden)
        .background(trioBackgroundColor)
        // WatchState times out a missing answer by showing a banner (beginAwaitingAcknowledgment), so every
        // request ends here. A timer in this view never started: the flag is already true when the view appears.
        .onChange(of: state.showAcknowledgmentBanner) { _, newValue in
            // A retry offer stays until the user answers it; a banner for the carbs sent with that bolus
            // must not close it
            if !newValue, state.refusedBolus == nil {
                // Navigate back to the root when acknowledgment banner disappears
                navigationPath.removeLast(navigationPath.count)
            }
        }
        .onChange(of: state.refusedBolus == nil) { _, isCleared in
            if !isCleared {
                WKInterfaceDevice.current().play(.failure)
            }
        }
        .onDisappear {
            state.shouldNavigateToRoot = true
        }
    }

    private var acknowledgmentView: some View {
        VStack {
            if state.isMealBolusCombo {
                ProgressView()
                Text(state.mealBolusStep.rawValue).multilineTextAlignment(.center)
            } else if state.showAcknowledgmentBanner {
                statusIcon.padding()
                Text(state.acknowledgmentMessage).multilineTextAlignment(.center)
                    .foregroundStyle(state.acknowledgementStatus == .failure ? Color.loopRed : Color.primary)
            } else if state.showCommsAnimation {
                ProgressView()
                Text("Processing…")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The pump was already bolusing, so the phone sent nothing to it. Retry goes back through the crown
    /// confirmation; if the pump is still bolusing then, the phone refuses again and this screen returns.
    private func refusedBolusView(_ refusedBolus: WatchState.RefusedBolus) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .font(.title2)
                    .foregroundStyle(Color.orange)

                Text("Pump Busy")
                    .font(.headline)

                Text(
                    String(
                        format: String(
                            localized: "A bolus is already in progress. Your %.2f U bolus was not sent.",
                            comment: "Watch message when a bolus was refused because the pump is already bolusing"
                        ),
                        refusedBolus.amount
                    )
                )
                .font(.footnote)
                .multilineTextAlignment(.center)

                if refusedBolus.carbsLogged {
                    Label("Carbs logged", systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(Color.loopGreen)
                }

                Text("Wait for the current bolus to finish, then retry.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    if state.prepareRefusedBolusRetry() {
                        // Back to the crown confirmation with only the bolus; carbs are not sent again
                        navigationPath = NavigationPath([NavigationDestinations.bolusConfirm])
                    }
                } label: {
                    Text("Retry Bolus")
                }
                .tint(Color.insulin)

                Button("Dismiss") {
                    state.dismissRefusedBolus()
                    navigationPath.removeLast(navigationPath.count)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
        }
    }
}
