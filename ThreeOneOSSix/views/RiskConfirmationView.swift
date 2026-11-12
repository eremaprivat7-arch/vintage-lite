import SwiftUI
import AudioToolbox

/// Full-screen red risk confirmation (YumEdit parity), required before every
/// experimental write. The copy is structured: what happens / worst case /
/// how to recover — concrete, not a generic "this is risky" warning.
struct RiskConfirmationView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss

    let titleKey: String
    /// Structured risk profile keys, resolved to the current language:
    /// "xxx.consequence" / "xxx.worst_case" / "xxx.recovery".
    let riskKey: String
    /// Fallback key chain (e.g. the preset's category keys): each section
    /// uses the first key whose translation exists, then falls back to
    /// `riskKey`. Preset risk copy ships as category-level strings, so the
    /// per-preset chain alone renders raw keys for presets without their own.
    var fallbackRiskKey: String?
    let confirmActionKey: String
    let onConfirm: () -> Void
    /// Called when the user backs out (Cancel or swipe-down) without
    /// confirming — lets callers roll staged state back.
    var onCancel: (() -> Void)?

    init(
        titleKey: String,
        riskKey: String,
        fallbackRiskKey: String? = nil,
        confirmActionKey: String,
        onCancel: (() -> Void)? = nil,
        onConfirm: @escaping () -> Void
    ) {
        self.titleKey = titleKey
        self.riskKey = riskKey
        self.fallbackRiskKey = fallbackRiskKey
        self.confirmActionKey = confirmActionKey
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    private func bodyKey(_ suffix: String) -> String {
        let primary = "\(riskKey).\(suffix)"
        if language.hasText(primary) { return primary }
        if let fallbackRiskKey {
            let fallback = "\(fallbackRiskKey).\(suffix)"
            if language.hasText(fallback) { return fallback }
        }
        return primary
    }

    @State private var holdProgress: Double = 0
    @State private var isHolding = false
    @State private var holdTimer: Timer?

    private var holdComplete: Bool { holdProgress >= 1 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label(language.text(titleKey), systemImage: "exclamationmark.triangle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(.top, 24)

                    riskSection(
                        icon: "info.circle",
                        titleKey: "risk.what_happens",
                        bodyKey: bodyKey("consequence")
                    )
                    riskSection(
                        icon: "exclamationmark.octagon",
                        titleKey: "risk.worst_case",
                        bodyKey: bodyKey("worst_case")
                    )
                    riskSection(
                        icon: "arrow.uturn.backward.circle",
                        titleKey: "risk.recovery",
                        bodyKey: bodyKey("recovery")
                    )
                }
                .padding(.horizontal, 20)
            }

            Divider()
            holdToConfirmControl
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
        .background(Color(uiColor: .systemBackground))
        .onDisappear { holdTimer?.invalidate() }
    }

    @ViewBuilder
    private func riskSection(icon: String, titleKey: String, bodyKey: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(language.text(titleKey), systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(language.text(bodyKey))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.red.opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }

    private var holdToConfirmControl: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(holdComplete ? Color.red : Color.red.opacity(0.85))
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.red.opacity(0.5))
                        .frame(width: geo.size.width * holdProgress)
                }
                .background(Color.clear)
                Text(holdComplete
                     ? language.text("risk.release_to_confirm")
                     : language.text("risk.hold_to_confirm"))
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHolding, !holdComplete else { return }
                        isHolding = true
                        startHoldTimer()
                    }
                    .onEnded { _ in
                        isHolding = false
                        holdTimer?.invalidate()
                        if holdComplete {
                            holdTimer?.invalidate()
                            SoundEffects.play(.warning)
                            onConfirm()
                            dismiss()
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) { holdProgress = 0 }
                        }
                    }
            )
            .accessibilityLabel(language.text("risk.hold_to_confirm"))
            .accessibilityAddTraits(.isButton)

            Button {
                onCancel?()
                dismiss()
            } label: {
                Text(language.text("common.cancel"))
                    .font(.subheadline)
            }
            .onDisappear {
                // Swipe-down dismissal without tapping Cancel still counts
                // as backing out; onConfirm already fired its own dismiss.
                if !holdComplete {
                    onCancel?()
                }
            }
        }
    }

    private func startHoldTimer() {
        holdProgress = 0
        let step: Double = 0.05
        holdTimer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { timer in
            withAnimation(.linear(duration: step)) {
                holdProgress = min(1, holdProgress + step / 1.2)
            }
            if holdProgress >= 1 {
                timer.invalidate()
            }
        }
    }
}

/// Minimal synthesized sound effects (YumEdit parity). No asset files: tones
/// are generated with AudioServices system sounds, toggleable in Settings.
enum SoundEffects {
    enum Effect {
        case tap
        case confirm
        case warning
        case success
        case failure
    }

    private static let systemSounds: [Effect: UInt32] = [
        .tap: 1104,       // soft tick
        .confirm: 1103,   // keyboard tap
        .warning: 1050,   // low warning
        .success: 1335,   // positive
        .failure: 1053,   // error
    ]

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "sound.effects.enabled") as? Bool ?? true
    }

    static func play(_ effect: Effect) {
        guard isEnabled, let id = systemSounds[effect] else { return }
        AudioServicesPlaySystemSound(id)
    }
}
