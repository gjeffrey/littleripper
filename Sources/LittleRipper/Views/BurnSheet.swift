import SwiftUI

/// Our own audio-CD burn progress UI (replaces the broken legacy DiscRecording panel).
struct BurnSheet: View {
    @ObservedObject var controller: BurnController
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: controller.failed != nil ? "exclamationmark.triangle.fill"
                  : controller.finished ? "checkmark.circle.fill" : "opticaldisc")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(controller.failed != nil ? .orange
                                 : controller.finished ? .green : .secondary)
                .symbolEffect(.pulse, isActive: !controller.finished)

            VStack(spacing: 4) {
                Text("Burning “\(controller.albumName)”")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(controller.stage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let failed = controller.failed {
                Text(failed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if controller.progress >= 0 {
                ProgressView(value: controller.progress)
                    .frame(width: 320)
            } else {
                ProgressView().frame(width: 320)
            }

            HStack {
                if controller.finished {
                    Button("Done", action: onClose)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { controller.cancel() }
                }
            }
        }
        .padding(28)
        .frame(width: 420)
    }
}
