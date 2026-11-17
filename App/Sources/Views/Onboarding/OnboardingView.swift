import CargoServices
import SwiftUI

/// Shown when no phone is connected: how to get one ready.
struct OnboardingView: View {
    let isADBInstalled: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Image(systemName: "cable.connector.horizontal")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Connect Your Android Phone")
                        .font(.title.bold())
                    Text("Plug it in with a USB cable. DroidCargo finds it automatically.")
                        .foregroundStyle(.secondary)
                }

                if !isADBInstalled {
                    SetupStepCard(step: .installTools, number: nil)
                }

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(SetupStep.phoneSteps.enumerated()), id: \.element) { index, step in
                        SetupStepCard(step: step, number: index + 1)
                    }
                }

                ConnectionHelpButton()
                    .buttonStyle(.hoverLink)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        // Start at the top even if a focused control sits further down.
        .defaultScrollAnchor(.top)
    }
}

/// Shown while the phone waits for the "Allow USB debugging?" tap.
struct AuthorizationView: View {
    let device: Device

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Unlock \(device.name) and Tap Allow")
            } icon: {
                Image(systemName: "lock.iphone")
            }
        } description: {
            Text("Your phone is asking whether to trust this Mac. Choose “Always allow from this computer” so you only do this once.")
        } actions: {
            ConnectionHelpButton()
        }
    }
}
