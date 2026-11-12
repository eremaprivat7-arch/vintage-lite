import SwiftUI

/// Region / Siri AI page (YumEdit parity): shows the current region
/// snapshot, native-model Siri AI enablement for verified machines, and the
/// experimental mode for older devices behind the full-screen risk
/// confirmation. All writes go through GestaltRegionService, which refuses
/// unknown machines and missing region fields before touching the cache.
struct GestaltRegionView: View {
    @Environment(\.appLanguage) private var language
    @State private var snapshot: GestaltRegionService.RegionSnapshot?
    @State private var isBusy = false
    @State private var showNativeConfirmation = false
    @State private var showExperimentalConfirmation = false
    @State private var activeAlert: RegionAlert?
    @State private var hasLoaded = false
    // Observable via SwiftUI: a plain UserDefaults read inside body would
    // never re-render when the Settings toggle flips.
    @AppStorage(FeatureVisibility.developerModeStorageKey) private var experimentalEnabled = false

    private var currentNativeModel: GestaltSiriModel? {
        guard let machine = snapshot?.machine else { return nil }
        return GestaltRegionService.siriNativeModels.first { $0.id == machine }
    }

    private var currentIPadModel: GestaltSiriModel? {
        guard let machine = snapshot?.machine else { return nil }
        return GestaltRegionService.siriIPadModels.first { $0.id == machine }
    }

    var body: some View {
        List {
            BackendNoticeBanner(unavailableKey: "backend.notice.region")
            snapshotSection
            nativeSection
            experimentalSection
        }
        .navigationTitle(language.text("gestalt.region.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { reload() }
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            reload()
        }
        .sheet(isPresented: $showNativeConfirmation) {
            RiskConfirmationView(
                titleKey: "gestalt.region.native_confirm_title",
                riskKey: "risk.gestalt.regionNative",
                confirmActionKey: "common.confirm"
            ) {
                applyNative()
            }
        }
        .sheet(isPresented: $showExperimentalConfirmation) {
            RiskConfirmationView(
                titleKey: "gestalt.region.experimental_confirm_title",
                riskKey: "risk.gestalt.regionExperimental",
                confirmActionKey: "common.confirm"
            ) {
                applyExperimental()
            }
        }
        .alert(item: $activeAlert, content: alertContent)
    }

    // MARK: - Sections

    private var snapshotSection: some View {
        Section {
            if let snapshot {
                LabeledContent(language.text("gestalt.region.machine")) {
                    Text(snapshot.machine)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent(language.text("gestalt.region.country")) {
                    Text(snapshot.country).font(.caption.monospaced())
                }
                LabeledContent(language.text("gestalt.region.sales")) {
                    Text(snapshot.region).font(.caption.monospaced())
                }
                LabeledContent(language.text("gestalt.region.regulatory")) {
                    Text(snapshot.regulatory).font(.caption.monospaced())
                }
            } else {
                Text(language.text("gestalt.region.error.missing_fields"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label(language.text("gestalt.region.snapshot_header"), systemImage: "globe")
        } footer: {
            Text(language.text("gestalt.region.snapshot_footer"))
        }
    }

    private var nativeSection: some View {
        Section {
            if let native = currentNativeModel {
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.text("gestalt.region.native_model", native.name))
                        .font(.subheadline.weight(.medium))
                    Text(language.text("gestalt.region.native_detail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    showNativeConfirmation = true
                } label: {
                    Label(language.text("gestalt.region.native_apply"), systemImage: "sparkles")
                }
                .disabled(isBusy)
            } else if currentIPadModel != nil {
                Text(language.text("gestalt.region.ipad_native_note"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(language.text("gestalt.region.native_unavailable"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label(language.text("gestalt.region.native_header"), systemImage: "brain.head.profile")
        }
    }

    private var experimentalSection: some View {
        // Hidden entirely until the user opts in via Settings → 实验功能.
        // @AppStorage drives invalidation: flipping the toggle updates the
        // section immediately.
        Group {
            if experimentalEnabled {
                Section {
                    let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
                    if osMajor < 27 {
                        Text(language.text("gestalt.region.error.needs_ios27"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Button(role: .destructive) {
                            showExperimentalConfirmation = true
                        } label: {
                            Label(language.text("gestalt.region.experimental_apply"), systemImage: "exclamationmark.triangle")
                        }
                        .disabled(isBusy || (snapshot?.machine.hasPrefix("iPad") == true && currentIPadModel == nil))
                    }
                } header: {
                    Label(language.text("gestalt.region.experimental_header"), systemImage: "flask")
                } footer: {
                    Text(language.text("gestalt.region.experimental_footer"))
                }
            }
        }
    }

    // MARK: - Actions

    private func reload() {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = try? GestaltRegionService.snapshot()
            DispatchQueue.main.async {
                snapshot = loaded
                isBusy = false
            }
        }
    }

    private func applyNative() {
        guard let native = currentNativeModel else { return }
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try GestaltRegionService.applySiriAINative(nativeModel: native)
                let loaded = try? GestaltRegionService.snapshot()
                DispatchQueue.main.async {
                    snapshot = loaded
                    isBusy = false
                    SoundEffects.play(.success)
                }
            } catch {
                DispatchQueue.main.async {
                    isBusy = false
                    SoundEffects.play(.failure)
                    activeAlert = .message(language.errorText(error))
                }
            }
        }
    }

    /// Experimental mode needs a spoof target. iPhones pick the native-AI
    /// profile closest to their family; the UI flow applies the first
    /// verified profile (YumEdit applies a user-selected one — the choice
    /// UI lands with the region editor refinement pass).
    private func applyExperimental() {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let machine = snapshot?.machine ?? ""
                let isPad = machine.hasPrefix("iPad")
                let table = isPad ? GestaltRegionService.siriIPadModels : GestaltRegionService.siriNativeModels
                guard let target = table.first else {
                    throw GestaltRegionError.unknownMachine
                }
                try GestaltRegionService.applySiriAIExperimental(spoofModel: target)
                let loaded = try? GestaltRegionService.snapshot()
                DispatchQueue.main.async {
                    snapshot = loaded
                    isBusy = false
                }
            } catch {
                DispatchQueue.main.async {
                    isBusy = false
                    activeAlert = .message(language.errorText(error))
                }
            }
        }
    }

    private func alertContent(for alert: RegionAlert) -> Alert {
        Alert(
            title: Text(language.text("gestalt.region.title")),
            message: Text(alert.message),
            dismissButton: .default(Text(language.text("common.ok")))
        )
    }
}

enum RegionAlert: Identifiable {
    case message(String)

    var message: String {
        if case .message(let value) = self { return value }
        return ""
    }

    var id: String { "region-\(message)" }
}
