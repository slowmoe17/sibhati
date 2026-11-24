import SwiftUI

struct ProbeView: View {
    @StateObject private var recorder = ProbeRecorder()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("سبحة · Motion Test")
                    .font(.headline)
                Text(recorder.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if recorder.isRunning {
                    Text("\(recorder.secondsRemaining)")
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("\(recorder.sampleCount) samples")
                        .font(.caption)
                    Button("Stop", role: .destructive) { recorder.cancel() }
                } else {
                    Picker("Test", selection: $recorder.kind) {
                        ForEach(CaptureKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    Picker("Position", selection: $recorder.posture) {
                        ForEach(WristPosture.allCases) { posture in
                            Text(posture.title).tag(posture)
                        }
                    }
                    Text(instructions)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Start 30-second test") { recorder.start() }
                        .tint(.teal)
                        .disabled(!recorder.canRecord || scenePhase != .active)
                    if let capture = recorder.latest, let summary = recorder.summary {
                        captureResult(capture, summary)
                    }
                }
                #if targetEnvironment(simulator)
                Text("Simulator: motion and vibration need a real Watch.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                #endif
            }
            .padding(.horizontal, 6)
        }
        .onAppear { updateDisplayState() }
        .onChange(of: dimmed) { _ in updateDisplayState() }
        .onChange(of: scenePhase) { _ in updateDisplayState() }
    }

    private var instructions: String {
        let position = recorder.posture == .lowered ? "Lower your wrist." : "Keep your wrist raised."
        let action: String
        switch recorder.kind {
        case .doublePinch: action = "Make 10 double pinches, about 3 seconds apart. Use the hand wearing the Watch."
        case .normalMovement: action = "Move your hand normally. Do not pinch."
        case .still: action = "Keep your hand still. Do not pinch."
        case .haptics: action = "Keep still. Expect 5 clicks, 5 seconds apart. Remember how many you feel."
        }
        return "After Start, wait 5 seconds. \(position) \(action) Each test records for 30 seconds."
    }

    @ViewBuilder
    private func captureResult(_ capture: Capture, _ summary: CaptureSummary) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: 5) {
            Text("Last: \(capture.kind.title)")
                .font(.caption)
            Text(capture.posture.title)
            Text("Status: \(capture.status == "recording" ? "interrupted" : capture.status)")
            Text("Samples: \(summary.sampleCount)")
            Text(String(format: "Coverage: %.1f seconds", summary.sampleSpan))
            Text(String(format: "Rate: %.1f Hz", summary.observedHz))
            Text(String(format: "Largest gap: %.3f s", summary.largestGap))
            Text("Dimmed samples: \(summary.dimmedSampleCount)")
            if capture.kind == .haptics {
                Text("Clicks requested: \(recorder.hapticRequests)")
                Text("Note how many clicks you felt.")
            }
            if summary.sampleCount == 0 {
                Text("No motion data. This test does not prove gesture support.")
                    .foregroundStyle(.orange)
            }
            if let url = recorder.exportURL {
                ShareLink(item: url) { Label("Share CSV", systemImage: "square.and.arrow.up") }
            }
        }
        .font(.caption2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func updateDisplayState() {
        recorder.displayChanged(dimmed: dimmed, scene: scenePhase)
    }
}
