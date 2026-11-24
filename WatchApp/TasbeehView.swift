import SwiftUI

struct TasbeehView: View {
    @StateObject private var model = TasbeehModel()
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            if let counter = model.counter {
                countingView(counter)
            } else {
                setupView
            }
        }
    }

    private var setupView: some View {
        VStack(spacing: 10) {
            Text("سبحة")
                .font(.headline)
            Text("لكل ذكر")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(TasbeehCounter.allowedTargets, id: \.self) { target in
                    Button("\(target)") { model.start(target: target) }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            if !model.status.isEmpty {
                Text(model.status)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            NavigationLink("اختبار الحركة") { ProbeView() }
                .font(.caption2)
        }
        .padding(.horizontal, 8)
    }

    private func countingView(_ counter: TasbeehCounter) -> some View {
        VStack(spacing: 4) {
            Button(action: model.tap) {
                VStack(spacing: 4) {
                    Text(counter.statement.text)
                        .font(.title3)
                    Text("\(counter.countInRound)")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("من \(counter.target)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .countingGesture()

            HStack(spacing: 6) {
                ForEach(TasbeehStatement.allCases) { statement in
                    VStack(spacing: 0) {
                        Text("\(counter.totals[statement] ?? 0)")
                            .font(.caption2)
                            .monospacedDigit()
                        Text(shortLabel(statement))
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statement == counter.statement ? Color.teal.opacity(0.3) : Color.clear,
                                in: .rect(cornerRadius: 6))
                }
            }

            HStack {
                Text("الإجمالي \(counter.grandTotal)")
                    .font(.caption2)
                    .monospacedDigit()
                Spacer()
                Button("إعادة") { confirmReset = true }
                    .font(.caption2)
                    .tint(.red)
            }
            .padding(.horizontal, 4)
            .confirmationDialog("مسح كل العدّادات؟", isPresented: $confirmReset) {
                Button("مسح", role: .destructive) { model.reset() }
                Button("إلغاء", role: .cancel) {}
            }
        }
        .padding(.horizontal, 4)
    }

    private func shortLabel(_ statement: TasbeehStatement) -> String {
        switch statement {
        case .subhanAllah: return "سبحان"
        case .alhamdulillah: return "الحمد"
        case .allahuAkbar: return "أكبر"
        }
    }
}

extension View {
    /// The native double tap (thumb + index) counts too. The API exists only in the
    /// watchOS 11 SDK (Xcode 16+); older toolchains build without it.
    @ViewBuilder
    func countingGesture() -> some View {
        #if compiler(>=6.0)
        if #available(watchOS 11.0, *) {
            self.handGestureShortcut(.primaryAction)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
