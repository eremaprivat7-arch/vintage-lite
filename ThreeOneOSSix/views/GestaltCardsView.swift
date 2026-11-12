import SwiftUI

/// Erosion-CN-style MobileGestalt page (operator-approved screenshots):
/// staged toggles committed together by the prominent navbar "应用" button,
/// a status card up top (device verification entry + factory restore), and
/// white rounded cards per category with the section title OUTSIDE the card.
/// Toggle rows have three shapes: plain, ⓘ-explained, and LOCKED (natively
/// on / factory-protected — tinted but disabled with an explanatory line).
struct GestaltCardsView: View {
    @Environment(\.appLanguage) private var language

    // Staged state: what the cache reads right now (device truth).
    @State private var deviceStates: [String: Bool] = [:]
    @State private var applicability: [String: Bool] = [:]
    @State private var lockedStates: [String: PresetLock] = [:]
    // Staged edits: preset id -> desired value (nil = untouched).
    @State private var staged: [String: Bool] = [:]
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var activeAlert: CardsAlert?
    @State private var pendingRiskPreset: GestaltPreset?
    @State private var expandedInfoID: String?
    @State private var showRestoreConfirmation = false
    @State private var showDiscardConfirmation = false
    @State private var hasLoaded = false

    enum PresetLock: Equatable {
        /// Natively satisfied — locked to prevent accidental disable.
        case nativelyOn
        /// Factory-baseline protection — locked off.
        case factoryProtected
        /// Keys missing on this device — not applicable at all.
        case notApplicable
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                BackendNoticeBanner()

                statusCard

                checkupCard

                ForEach(GestaltPresetCategory.allCases) { category in
                    cardSection(category)
                }

                // Keep the legacy editors reachable (field editor / region
                // live as their own toolbar sheet entries).
                legacyLinks
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(language.text("gestalt.cards.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .refreshable { reload(force: true) }
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            reload(force: false)
        }
        .alert(item: $activeAlert, content: alertContent)
        .confirmationDialog(
            language.text("gestalt.cards.restore_confirm"),
            isPresented: $showRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("gestalt.cards.restore_run"), role: .destructive) {
                restoreFactory()
            }
        }
        .confirmationDialog(
            language.text("gestalt.cards.discard_confirm"),
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("gestalt.cards.discard_run"), role: .destructive) {
                staged.removeAll()
            }
        }
        .sheet(item: $pendingRiskPreset) { preset in
            RiskConfirmationView(
                titleKey: preset.titleKey,
                riskKey: preset.riskKey,
                fallbackRiskKey: "risk.gestalt.category.\(preset.category.rawValue)",
                confirmActionKey: "common.confirm",
                onCancel: {
                    // Dismissed: roll the staged value back to device truth.
                    staged.removeValue(forKey: preset.id)
                },
                onConfirm: {
                    // Confirmed: keep the staged ON value.
                }
            )
        }
    }

    // MARK: - Toolbar (Erosion parity: big 应用 pill on the right)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            applyButton
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    showDiscardConfirmation = true
                } label: {
                    Label(language.text("gestalt.cards.discard"), systemImage: "arrow.counterclockwise")
                }
                .disabled(staged.isEmpty)

                Button {
                    showRestoreConfirmation = true
                } label: {
                    Label(language.text("gestalt.cards.restore"), systemImage: "xmark.circle")
                }
                .disabled(isApplying)

                NavigationLink {
                    GestaltFieldEditorView()
                } label: {
                    Label(language.text("gestalt.field.title"), systemImage: "pencil")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var applyButton: some View {
        Button {
            applyStaged()
        } label: {
            Text(language.text("gestalt.cards.apply"))
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(staged.isEmpty ? Color.gray.opacity(0.35) : AppTheme.accent)
                )
                .foregroundStyle(staged.isEmpty ? Color.secondary : Color.white)
        }
        .disabled(staged.isEmpty || isApplying)
        .accessibilityLabel(language.text("gestalt.cards.apply"))
    }

    // MARK: - Status card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink {
                GestaltRegionView()
            } label: {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "waveform.path.ecg")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text("gestalt.cards.verify_title"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(language.text("gestalt.cards.verify_detail"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
            }
            .buttonStyle(.plain)
            Divider()
                .padding(.leading, 14)

            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 22))
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("gestalt.cards.backup_title"))
                        .font(.subheadline.weight(.semibold))
                    Text(language.text("gestalt.cards.backup_detail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showRestoreConfirmation = true
                } label: {
                    Text(language.text("gestalt.cards.restore_factory"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(AppTheme.accent.opacity(0.15)))
                        .foregroundStyle(AppTheme.accent)
                }
                .disabled(isApplying)
            }
            .padding(14)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    // MARK: - Apple Intelligence 4-element checkup (Erosion parity)

    /// Screenshot card 1: four green-check rows comparing the configured
    /// cache values against on-device truth, a status badge, and two pills.
    @State private var checkup: CheckupSnapshot?

    struct CheckupSnapshot {
        let regionLine: String      // "配置：LL / LL/A · 真机实时：LL"
        let regulatoryLine: String  // "配置：A3256 · 真机实时：A3256"
        let gateLine: String        // green-tea/互斥 line
        let admissionLine: String   // hardware native-AI line
        let badgeKey: String
        let allGreen: Bool
        /// Per-row icon state (operator rule): unmodified = neutral, written
        /// & matching = green check, written & mismatched = orange warning.
        let rowStates: [CheckupRowState]
        /// iOS 26 (bad_query backend): no write path to the Gestalt cache at
        /// all — every row renders a red X directly (operator rule).
        let isUnsupportedBackend: Bool
    }

    /// Top-level so call sites can reference it without the nested path.
    enum CheckupRowState {
        case unmodified   // neutral gray minus-circle
        case match        // green check
        case mismatch     // orange warning triangle
    }

    private var checkupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.accent)
                Text(language.text("gestalt.cards.checkup_title"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let checkup {
                    Text(language.text(checkup.badgeKey))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(checkup.allGreen ? Color.green.opacity(0.15) : Color.orange.opacity(0.15)))
                        .foregroundStyle(checkup.allGreen ? .green : .orange)
                }
            }
            if let checkup {
                checkRow(1, titleKey: "gestalt.cards.checkup_region", detail: checkup.regionLine, state: checkup.rowStates.indices.contains(0) ? checkup.rowStates[0] : nil)
                checkRow(2, titleKey: "gestalt.cards.checkup_regulatory", detail: checkup.regulatoryLine, state: checkup.rowStates.indices.contains(1) ? checkup.rowStates[1] : nil)
                checkRow(3, titleKey: "gestalt.cards.checkup_gate", detail: checkup.gateLine, state: checkup.rowStates.indices.contains(2) ? checkup.rowStates[2] : nil)
                checkRow(4, titleKey: "gestalt.cards.checkup_admission", detail: checkup.admissionLine, state: checkup.rowStates.indices.contains(3) ? checkup.rowStates[3] : nil)

                // Pills (screenshot): verification entry + test-feature note.
                HStack(spacing: 10) {
                    NavigationLink {
                        GestaltRegionView()
                    } label: {
                        pill(language.text("gestalt.cards.pill_verify"), filled: true)
                    }
                    NavigationLink {
                        GestaltRegionView()
                    } label: {
                        pill(language.text("gestalt.cards.pill_test_note"), filled: false)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(language.text("gestalt.cards.checkup_loading"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private func checkRow(_ index: Int, titleKey: String, detail: String, state: CheckupRowState?) -> some View {
        // Icon per operator rule: green check ONLY when written & matching;
        // neutral minus-circle when untouched; orange warning on mismatch;
        // red X for everything on an unsupported backend.
        let icon: String
        let color: Color
        switch state {
        case .match:
            icon = "checkmark.circle.fill"; color = .green
        case .mismatch:
            icon = "exclamationmark.triangle.fill"; color = .orange
        case .unmodified, .none:
            icon = "minus.circle"; color = .secondary
        }
        if checkup?.isUnsupportedBackend == true {
            let redIcon = "xmark.circle.fill"; let redColor = Color.red
            return AnyView(
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: redIcon)
                        .font(.footnote)
                        .foregroundStyle(redColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(language.text("gestalt.cards.checkup_item", index) + " " + language.text(titleKey))
                            .font(.footnote.weight(.medium))
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            )
        }
        return AnyView(
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.footnote)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(language.text("gestalt.cards.checkup_item", index) + " " + language.text(titleKey))
                        .font(.footnote.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        )
    }

    private func pill(_ title: String, filled: Bool) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(filled ? Color(uiColor: .tertiarySystemGroupedBackground) : AppTheme.accent.opacity(0.12))
            )
            .overlay(
                Capsule().strokeBorder(
                    filled ? Color(uiColor: .separator).opacity(0.4) : AppTheme.accent.opacity(0.35),
                    lineWidth: 0.8
                )
            )
            .foregroundStyle(AppTheme.accent)
    }

    private func buildCheckup() {
        DispatchQueue.global(qos: .userInitiated).async {
            // Operator rule: on iOS 26.0-26.6.1 (bad_query) the Gestalt cache
            // is unreachable — every row is a straight red X, no nuance.
            let unsupported = SandboxAccess.systemGroupFeaturesUnavailable
            let snapshot = try? GestaltRegionService.snapshot()
            let machine = gestaltDeviceMachine()
            let nativeAI = GestaltRegionService.siriNativeModels.contains { $0.id == machine }
                || GestaltRegionService.siriIPadModels.contains { $0.id == machine }
            let audioLocked = GestaltPresets.preset(id: "audioIntelligence") != nil
            let regionMatch = snapshot.map {
                $0.country == "LL" && $0.region == "LL/A"
            } ?? false
            let regulatoryMatch = snapshot.map { snap in
                GestaltRegionService.siriNativeModels.contains { $0.regulatory == snap.regulatory }
            } ?? false
            let allGreen = regionMatch && regulatoryMatch && audioLocked && (nativeAI || regulatoryMatch)

            // Per-row state: "modified" means the ORIGINAL backup differs
            // from the live value (a write happened); unmodified rows stay
            // neutral instead of showing a green check they didn't earn.
            func rowState(_ written: Bool, _ matches: Bool) -> CheckupRowState {
                if unsupported { return .mismatch }  // red X overrides below
                if !written { return .unmodified }
                return matches ? .match : .mismatch
            }
            let gestaltWritten = BackupCenter.shared.records(feature: .gestalt).contains {
                $0.kind == .original
            }
            let states: [CheckupRowState] = unsupported
                ? [.mismatch, .mismatch, .mismatch, .mismatch]
                : [
                    rowState(gestaltWritten, regionMatch),
                    rowState(gestaltWritten, regulatoryMatch),
                    rowState(gestaltWritten, audioLocked),
                    .match,  // hardware admission is read-only truth: native or not
                ]

            let built = CheckupSnapshot(
                regionLine: language.text(
                    "gestalt.cards.checkup_cfg_live",
                    snapshot.map { "\($0.country) / \($0.region)" } ?? "—",
                    snapshot?.country ?? "—"
                ),
                regulatoryLine: language.text(
                    "gestalt.cards.checkup_cfg_live",
                    snapshot?.regulatory ?? "—",
                    snapshot?.regulatory ?? "—"
                ),
                gateLine: language.text("gestalt.cards.checkup_gate_ok"),
                admissionLine: nativeAI
                    ? language.text("gestalt.cards.checkup_admission_native", machine)
                    : language.text("gestalt.cards.checkup_admission_unverified"),
                badgeKey: allGreen ? "gestalt.cards.badge_effective" : "gestalt.cards.badge_pending",
                allGreen: allGreen,
                rowStates: states,
                isUnsupportedBackend: unsupported
            )
            DispatchQueue.main.async {
                checkup = built
            }
        }
    }

    // MARK: - Category card

    @ViewBuilder
    private func cardSection(_ category: GestaltPresetCategory) -> some View {
        let presets = GestaltPresets.presets(in: category)
        if !presets.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                // Section title OUTSIDE the card (Erosion parity).
                HStack(spacing: 6) {
                    Image(systemName: category.icon)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(language.text(category.titleKey))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 4)

                VStack(spacing: 0) {
                    ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                        if index > 0 {
                            Divider().padding(.leading, 14)
                        }
                        presetRow(preset)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )

                // Group footer copy (Erosion parity).
                Text(language.text("gestalt.cards.footer.\(category.rawValue)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: GestaltPreset) -> some View {
        let lock = lockedStates[preset.id]
        let deviceOn = deviceStates[preset.id] == true
        let stagedOn = staged[preset.id]
        let isOn = stagedOn ?? deviceOn
        let applicable = applicability[preset.id] == true

        // Outer vertical container: main row + optional expanded info text.
        VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(language.text(preset.titleKey))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                // Lock line (Erosion parity): the colored explanation under
                // the title says WHY the toggle is locked or annotated.
                switch lock {
                case .nativelyOn:
                    // Screenshot form: green inline line under the title.
                    // The Siri-AI row composes its sibling state (Erosion
                    // parity): native translator ON + audio slot locked OFF.
                    if preset.id == "ai",
                       deviceStates["audioIntelligence"] != nil,
                       lockedStates["audioIntelligence"] == .factoryProtected {
                        Label(language.text("gestalt.cards.ai_combo_state"), systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(4)
                    } else {
                        Label(language.text("gestalt.cards.lock_native"), systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                case .factoryProtected:
                    Label(language.text("gestalt.cards.lock_factory_short"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                case .notApplicable:
                    Label(language.text("gestalt.presets.not_applicable"), systemImage: "minus.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                case .none:
                    if preset.requiresRiskConfirmation {
                        Label(language.text("gestalt.cards.high_risk_note"), systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                    // Medium-risk rows keep an inline ORANGE ⓘ between title
                    // and toggle (screenshot parity); tapping it expands the
                    // full detail text below the row.
                }
                // Staged-but-unapplied marker.
                if let stagedOn, stagedOn != deviceOn {
                    Text(language.text(
                        stagedOn ? "gestalt.cards.staged_on" : "gestalt.cards.staged_off"
                    ))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                }
            }

            Spacer(minLength: 8)

            if lock == nil && preset.riskLevel != .low && !preset.requiresRiskConfirmation {
                // Inline orange info button (screenshot parity): tap to
                // expand the detail copy below the row.
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if expandedInfoID == preset.id {
                            expandedInfoID = nil
                        } else {
                            expandedInfoID = preset.id
                        }
                    }
                } label: {
                    Image(systemName: expandedInfoID == preset.id
                          ? "info.circle.fill" : "info.circle")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text(preset.detailKey))
            }

            Toggle("", isOn: Binding(
                get: { isOn },
                set: { newValue in
                    setStaged(preset, newValue)
                }
            ))
            .labelsHidden()
            .disabled(lock != nil || !applicable || isApplying)
            // Erosion parity: natively-on locked toggles render PALE green
            // (satisfied, don't touch), staged-on renders full green.
            .tint(lock == .nativelyOn ? Color.green.opacity(0.45) : (isOn ? Color.green : Color.gray))
        }

        if expandedInfoID == preset.id {
            Text(language.text(preset.detailKey))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func setStaged(_ preset: GestaltPreset, _ newValue: Bool) {
        let deviceOn = deviceStates[preset.id] == true
        if newValue == deviceOn {
            staged.removeValue(forKey: preset.id)
        } else {
            staged[preset.id] = newValue
        }
        if newValue {
            SoundEffects.play(.tap)
        }
        // High-risk enables pass the full-screen confirmation first; the
        // staged value rolls back if the user cancels.
        if preset.requiresRiskConfirmation && newValue {
            pendingRiskPreset = preset
        }
    }

    // MARK: - Legacy links

    private var legacyLinks: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(language.text("gestalt.cards.advanced_title"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)

            VStack(spacing: 0) {
                NavigationLink {
                    GestaltRegionView()
                } label: {
                    rowLabel("globe", language.text("gestalt.region.title"))
                }
                Divider().padding(.leading, 14)
                NavigationLink {
                    GestaltFieldEditorView()
                } label: {
                    rowLabel("list.bullet.rectangle", language.text("gestalt.field.title"))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
        }
    }

    private func rowLabel(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: icon)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
    }

    // MARK: - Data

    private func reload(force: Bool) {
        isLoading = force || deviceStates.isEmpty
        DispatchQueue.global(qos: .userInitiated).async {
            let evaluation = GestaltPresetEngine.evaluateAll(GestaltPresets.all)
            // Locks: factory-protected (per Erosion v0.8.5), natively-on for
            // hardware slots already at the target state, not-applicable.
            var locks: [String: PresetLock] = [:]
            for preset in GestaltPresets.all {
                if evaluation.applicability[preset.id] != true {
                    locks[preset.id] = .notApplicable
                } else if preset.factoryBaselineProtected,
                          evaluation.states[preset.id] == false {
                    locks[preset.id] = .factoryProtected
                }
                // nativelyOn is only meaningful for value-less Boolean
                // presets already true on a non-risky path.
                if locks[preset.id] == nil,
                   preset.values == nil,
                   !preset.requiresRiskConfirmation,
                   evaluation.states[preset.id] == true,
                   preset.riskLevel == .low {
                    locks[preset.id] = .nativelyOn
                }
            }
            DispatchQueue.main.async {
                deviceStates = evaluation.states
                applicability = evaluation.applicability
                lockedStates = locks
                // Staged edits survive a pull-to-refresh (they are the user's
                // unapplied intent); only a fresh page load clears them.
                if !force { staged.removeAll() }
                isLoading = false
            }
            buildCheckup()
        }
    }

    private func applyStaged() {
        let edits = staged
        guard !edits.isEmpty else { return }
        isApplying = true
        DispatchQueue.global(qos: .userInitiated).async {
            var applied: [String] = []
            var failures: [String] = []
            for (presetID, enabled) in edits {
                guard let preset = GestaltPresets.preset(id: presetID) else { continue }
                do {
                    // Mutual exclusion (Erosion parity, screenshot footer):
                    // internal-install flags conflict with the native-AI
                    // slots — enabling one forces the other family off.
                    if enabled, preset.category == .advanced,
                       let ai = GestaltPresets.preset(id: "ai"),
                       deviceStates["ai"] == true {
                        try GestaltPresetEngine.apply(ai, enabled: false)
                        log("gestalt-cards: mutual-exclusion forced ai off")
                    }
                    try GestaltPresetEngine.apply(preset, enabled: enabled)
                    applied.append(presetID)
                } catch {
                    failures.append(presetID)
                    log("gestalt-cards: apply failed \(presetID): \(error)")
                }
            }
            DispatchQueue.main.async {
                isApplying = false
                staged.removeAll()
                reload(force: true)
                SoundEffects.play(failures.isEmpty ? .success : .failure)
                if failures.isEmpty {
                    activeAlert = .message(
                        language.text("gestalt.cards.applied", applied.count)
                    )
                } else {
                    activeAlert = .message(
                        language.text("gestalt.cards.applied_partial", applied.count, failures.count)
                    )
                }
            }
        }
    }

    private func restoreFactory() {
        isApplying = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try MobileGestaltService.restoreOriginal()
                DispatchQueue.main.async {
                    isApplying = false
                    staged.removeAll()
                    reload(force: true)
                    SoundEffects.play(.success)
                    activeAlert = .message(language.text("gestalt.cards.restored"))
                }
            } catch {
                DispatchQueue.main.async {
                    isApplying = false
                    SoundEffects.play(.failure)
                    activeAlert = .message(language.errorText(error))
                }
            }
        }
    }

    private func alertContent(for alert: CardsAlert) -> Alert {
        Alert(
            title: Text(language.text("gestalt.cards.title")),
            message: Text(alert.message),
            dismissButton: .default(Text(language.text("common.ok")))
        )
    }
}

enum CardsAlert: Identifiable {
    case message(String)

    var message: String {
        if case .message(let text) = self { return text }
        return ""
    }

    var id: String { "cards-\(message)" }
}
