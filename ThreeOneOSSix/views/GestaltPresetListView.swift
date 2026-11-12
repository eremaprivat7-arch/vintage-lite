import SwiftUI

/// Preset library (GestaltX categories): display / device / iPad /
/// intelligence / advanced. Each row shows the live on/off state read from
/// the device cache; identity-level presets and the Advanced category route
/// through the full-screen RiskConfirmationView before any write. Presets
/// whose keys do not exist on this device are disabled with a reason —
/// never written blindly (iOS 27 anti-bounce rule).
struct GestaltPresetListView: View {
    @Environment(\.appLanguage) private var language
    @State private var states: [String: Bool?] = [:]
    @State private var applicability: [String: Bool] = [:]
    @State private var isBusy = false
    @State private var pendingConfirmation: GestaltPreset?
    @State private var activeAlert: PresetAlert?
    @State private var hasLoaded = false

    var body: some View {
        List {
            BackendNoticeBanner()
            ForEach(GestaltPresetCategory.allCases) { category in
                Section {
                    ForEach(GestaltPresets.presets(in: category)) { preset in
                        presetRow(preset)
                    }
                } header: {
                    Label(language.text(category.titleKey), systemImage: category.icon)
                }
            }
        }
        .navigationTitle(language.text("gestalt.presets.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if isBusy { ProgressView() }
            }
        }
        .refreshable { reload() }
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            reload()
        }
        .sheet(item: $pendingConfirmation) { preset in
            RiskConfirmationView(
                titleKey: preset.titleKey,
                riskKey: preset.riskKey,
                fallbackRiskKey: "risk.gestalt.category.\(preset.category.rawValue)",
                confirmActionKey: "common.confirm"
            ) {
                apply(preset, enabled: true)
            }
        }
        .alert(item: $activeAlert, content: alertContent)
    }

    @ViewBuilder
    private func presetRow(_ preset: GestaltPreset) -> some View {
        let applicable = applicability[preset.id] ?? false
        Toggle(isOn: binding(for: preset)) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(language.text(preset.titleKey))
                        .foregroundStyle(.primary)
                    if preset.riskLevel == .high {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .accessibilityLabel(language.text("gestalt.presets.high_risk"))
                    }
                }
                Text(language.text(preset.detailKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !applicable {
                    Text(language.text("gestalt.presets.not_applicable"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .disabled(isBusy || !applicable)
    }

    private func binding(for preset: GestaltPreset) -> Binding<Bool> {
        Binding(
            get: { (states[preset.id] ?? false) == true },
            set: { newValue in
                if preset.requiresRiskConfirmation && newValue {
                    pendingConfirmation = preset
                } else {
                    apply(preset, enabled: newValue)
                }
            }
        )
    }

    // MARK: - Data

    private func reload() {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            // One plist read serves all 31 presets (was 62 full parses).
            let evaluation = GestaltPresetEngine.evaluateAll(GestaltPresets.all)
            var optionalStates: [String: Bool?] = [:]
            for preset in GestaltPresets.all {
                optionalStates[preset.id] = evaluation.states[preset.id]
            }
            DispatchQueue.main.async {
                states = optionalStates
                applicability = evaluation.applicability
                isBusy = false
            }
        }
    }

    private func apply(_ preset: GestaltPreset, enabled: Bool) {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // State comes back from the same in-memory root the apply
                // already had — no second 18MB read per toggle.
                let state = try GestaltPresetEngine.applyReportingState(preset, enabled: enabled)
                DispatchQueue.main.async {
                    states[preset.id] = state
                    isBusy = false
                    SoundEffects.play(.success)
                }
            } catch {
                DispatchQueue.main.async {
                    isBusy = false
                    SoundEffects.play(.failure)
                    activeAlert = .message(language.errorText(error))
                    reload()
                }
            }
        }
    }

    private func alertContent(for alert: PresetAlert) -> Alert {
        Alert(
            title: Text(language.text("gestalt.presets.title")),
            message: Text(alert.message),
            dismissButton: .default(Text(language.text("common.ok")))
        )
    }
}

enum PresetAlert: Identifiable {
    case message(String)

    var message: String {
        if case .message(let text) = self { return text }
        return ""
    }

    var id: String { "preset-\(message)" }
}
