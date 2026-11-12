import SwiftUI

/// Supervised Mode page (Regitela parity): shows the current state, flips
/// it behind the full-screen risk confirmation. The MDM warning is explicit
/// because flipping supervision on an MDM-managed device breaks the
/// management relationship.
struct SupervisedModeView: View {
    @Environment(\.appLanguage) private var language
    @State private var isSupervised: Bool?
    @State private var isBusy = false
    @State private var showConfirmation = false
    @State private var pendingValue = false
    @State private var activeAlert: SupervisedAlert?
    @State private var hasLoaded = false

    var body: some View {
        List {
            BackendNoticeBanner(unavailableKey: "backend.notice.supervised")
            Section {
                LabeledContent(language.text("supervised.state")) {
                    Text(stateText)
                        .foregroundStyle(isSupervised == true ? AppTheme.accent : .secondary)
                        .font(.headline.monospacedDigit())
                }
            } header: {
                Label(language.text("supervised.header"), systemImage: "checkmark.shield")
            } footer: {
                Text(SupervisedModeService.plistPath)
                    .font(.caption2.monospaced())
            }

            Section {
                Button {
                    pendingValue = true
                    showConfirmation = true
                } label: {
                    Label(language.text("supervised.enable"), systemImage: "shield.lefthalf.filled")
                }
                .disabled(isBusy || isSupervised == true)

                Button(role: .destructive) {
                    pendingValue = false
                    showConfirmation = true
                } label: {
                    Label(language.text("supervised.disable"), systemImage: "shield.slash")
                }
                .disabled(isBusy || isSupervised == false)

                Button {
                    reload()
                } label: {
                    Label(language.text("supervised.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(isBusy)
            } footer: {
                Text(language.text("supervised.warning"))
            }

            if let errorNote {
                Section {
                    Text(errorNote)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(language.text("supervised.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { reload() }
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            reload()
        }
        .sheet(isPresented: $showConfirmation) {
            RiskConfirmationView(
                titleKey: pendingValue ? "supervised.enable" : "supervised.disable",
                riskKey: "risk.supervised",
                confirmActionKey: "common.confirm"
            ) {
                apply(pendingValue)
            }
        }
        .alert(item: $activeAlert, content: alertContent)
    }

    private var stateText: String {
        switch isSupervised {
        case .some(true): return language.text("supervised.on")
        case .some(false): return language.text("supervised.off")
        case .none: return language.text("supervised.unknown")
        }
    }

    private var errorNote: String? {
        nil // reserved: surfaced through alerts for now
    }

    private func reload() {
        isBusy = true
        DispatchQueue.global(qos: .utility).async {
            let state = SupervisedModeService.currentState()
            DispatchQueue.main.async {
                isSupervised = state
                isBusy = false
            }
        }
    }

    private func apply(_ value: Bool) {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SupervisedModeService.apply(value)
                DispatchQueue.main.async {
                    isSupervised = SupervisedModeService.currentState()
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

    private func alertContent(for alert: SupervisedAlert) -> Alert {
        Alert(
            title: Text(language.text("supervised.title")),
            message: Text(alert.message),
            dismissButton: .default(Text(language.text("common.ok")))
        )
    }
}

enum SupervisedAlert: Identifiable {
    case message(String)

    var message: String {
        if case .message(let text) = self { return text }
        return ""
    }

    var id: String { "supervised-\(message)" }
}
