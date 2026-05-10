import SwiftUI

struct OnboardingView: View {
    @StateObject private var controller = OnboardingController()
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 18)
            VStack(spacing: 14) {
                ForEach(OnboardingStepKind.allCases) { step in
                    OnboardingRow(
                        step: step,
                        status: status(for: step),
                        isWorking: controller.isWorking,
                        onAction: { Task { await controller.runStep(step) } },
                        onSkip: { controller.skipStep(step) }
                    )
                }
            }
            Spacer(minLength: 24)
            footer
        }
        .padding(28)
        .frame(width: 540)
        .task {
            // Defer onboarding checks one runloop tick so AppKit has
            // a chance to publish Bundle.main into UserNotifications.
            // Without this, UNUserNotificationCenter.current() asserts
            // with `bundleProxyForCurrentProcess is nil` on first
            // launch from `open .app`.
            try? await Task.sleep(nanoseconds: 100_000_000)
            await controller.refreshAll()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome to Steer")
                .font(.system(size: 22, weight: .semibold))
            Text("Three quick checks before you launch your first session.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.bordered)
            Spacer()
            Button(action: finish) {
                Text(controller.isReadyToFinish ? "Done" : "Skip remaining and continue")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func status(for step: OnboardingStepKind) -> OnboardingStepStatus {
        switch step {
        case .cli: return controller.state.cli
        case .hooks: return controller.state.hooks
        case .notifications: return controller.state.notifications
        }
    }

    private func finish() {
        OnboardingController.markCompleted()
        onFinish()
    }
}

private struct OnboardingRow: View {
    let step: OnboardingStepKind
    let status: OnboardingStepStatus
    let isWorking: Bool
    let onAction: () -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            statusIcon
                .frame(width: 22, height: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detailText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            controls
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .satisfied:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 18))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 18))
        case .skipped:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
                .font(.system(size: 18))
        case .checking:
            ProgressView().controlSize(.small)
        case .actionable, .unknown:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .font(.system(size: 18))
        }
    }

    private var detailText: String {
        switch status {
        case .satisfied(let detail), .actionable(let detail), .failed(let detail):
            return detail
        case .skipped:
            return "Skipped — you can configure this later in Settings."
        case .checking:
            return "Working…"
        case .unknown:
            return step.detail
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch status {
        case .satisfied:
            EmptyView()
        case .skipped:
            Button("Run anyway", action: onAction)
                .buttonStyle(.bordered)
                .disabled(isWorking)
        case .checking:
            EmptyView()
        case .actionable, .unknown, .failed:
            HStack(spacing: 6) {
                Button("Skip", action: onSkip)
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
                Button(actionLabel, action: onAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
            }
        }
    }

    private var actionLabel: String {
        switch step {
        case .cli: return "Install"
        case .hooks: return "Wire up"
        case .notifications: return "Allow"
        }
    }
}
