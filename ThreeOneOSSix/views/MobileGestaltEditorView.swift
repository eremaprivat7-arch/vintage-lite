import SwiftUI

struct MobileGestaltEditorView: View {
    @Environment(\.appLanguage) private var language

    @State private var isLoading = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showApplyConfirmation = false
    @State private var showRestoreConfirmation = false
    @State private var notice: EditorNotice?

    @State private var deviceName = ""
    @State private var deviceSubtype = ""
    @State private var productType = ""
    @State private var dynamicIsland = false
    @State private var alwaysOnDisplay = false
    @State private var aodVibrancy = false
    @State private var chargeLimit = false
    @State private var bootChime = false

    private struct EditorNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        Form {
            BackendNoticeBanner()
            Section {
                Text(language.text("gestalt.safety"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if isLoading {
                Section {
                    HStack {
                        ProgressView()
                        Text(language.text("gestalt.loading"))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button(language.text("common.retry")) {
                        load()
                    }
                }
            } else {
                Section(language.text("gestalt.section.device")) {
                    TextField(language.text("gestalt.device_name"), text: $deviceName)
                        .textInputAutocapitalization(.never)
                    TextField(language.text("gestalt.subtype"), text: $deviceSubtype)
                        .keyboardType(.numberPad)
                    LabeledContent(language.text("gestalt.product_type"), value: productType)
                }

                Section(language.text("gestalt.section.features")) {
                    Toggle(language.text("gestalt.dynamic_island"), isOn: $dynamicIsland)
                    Toggle(language.text("gestalt.aod"), isOn: $alwaysOnDisplay)
                    Toggle(language.text("gestalt.aod_vibrancy"), isOn: $aodVibrancy)
                        .disabled(!alwaysOnDisplay)
                    Toggle(language.text("gestalt.charge_limit"), isOn: $chargeLimit)
                    Toggle(language.text("gestalt.boot_chime"), isOn: $bootChime)
                }

                Section(language.text("gestalt.section.advanced_tools")) {
                    NavigationLink {
                        GestaltPresetListView()
                    } label: {
                        Label(language.text("gestalt.presets.title"), systemImage: "switch.2")
                    }
                    NavigationLink {
                        GestaltFieldEditorView()
                    } label: {
                        Label(language.text("gestalt.field.title"), systemImage: "list.bullet.rectangle")
                    }
                    NavigationLink {
                        GestaltRegionView()
                    } label: {
                        Label(language.text("gestalt.region.title"), systemImage: "globe")
                    }
                }

                Section {
                    Button {
                        showApplyConfirmation = true
                    } label: {
                        Label(language.text("gestalt.apply"), systemImage: "checkmark.seal.fill")
                    }
                    .disabled(isWorking)

                    Button(role: .destructive) {
                        showRestoreConfirmation = true
                    } label: {
                        Label(language.text("gestalt.restore_original"), systemImage: "arrow.counterclockwise")
                    }
                    .disabled(isWorking)

                    RespringButton()
                } footer: {
                    Text(language.text("gestalt.footer"))
                }
            }
        }
        .navigationTitle(language.text("gestalt.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .alert(language.text("gestalt.apply_confirm_title"), isPresented: $showApplyConfirmation) {
            Button(language.text("gestalt.apply"), role: .destructive) {
                apply()
            }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("gestalt.apply_confirm_message"))
        }
        .alert(language.text("gestalt.restore_confirm_title"), isPresented: $showRestoreConfirmation) {
            Button(language.text("gestalt.restore_original"), role: .destructive) {
                restoreOriginal()
            }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("gestalt.restore_confirm_message"))
        }
        .alert(item: $notice) { value in
            Alert(
                title: Text(value.title),
                message: Text(value.message),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
        .overlay {
            if isWorking {
                ProgressView()
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func load() {
        isLoading = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let state = try MobileGestaltService.load()
                DispatchQueue.main.async {
                    deviceName = state.deviceName
                    deviceSubtype = String(state.deviceSubtype)
                    productType = state.productType
                    dynamicIsland = state.dynamicIsland
                    alwaysOnDisplay = state.alwaysOnDisplay
                    aodVibrancy = state.aodVibrancy
                    chargeLimit = state.chargeLimit
                    bootChime = state.bootChime
                    isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    isLoading = false
                    errorMessage = localized(error)
                }
            }
        }
    }

    private func apply() {
        guard let subtype = Int(deviceSubtype), (0...100_000).contains(subtype) else {
            notice = EditorNotice(
                title: language.text("gestalt.error_title"),
                message: language.text("gestalt.error.value")
            )
            return
        }
        let state = MobileGestaltState(
            deviceName: deviceName,
            deviceSubtype: subtype,
            productType: productType,
            dynamicIsland: dynamicIsland,
            alwaysOnDisplay: alwaysOnDisplay,
            aodVibrancy: aodVibrancy && alwaysOnDisplay,
            chargeLimit: chargeLimit,
            bootChime: bootChime
        )
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try MobileGestaltService.apply(state)
                DispatchQueue.main.async {
                    isWorking = false
                    notice = EditorNotice(
                        title: language.text("gestalt.applied_title"),
                        message: language.text("gestalt.applied_message")
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    isWorking = false
                    notice = EditorNotice(
                        title: language.text("gestalt.error_title"),
                        message: localized(error)
                    )
                }
            }
        }
    }

    private func restoreOriginal() {
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try MobileGestaltService.restoreOriginal()
                DispatchQueue.main.async {
                    isWorking = false
                    notice = EditorNotice(
                        title: language.text("gestalt.restored_title"),
                        message: language.text("gestalt.restored_message")
                    )
                    load()
                }
            } catch {
                DispatchQueue.main.async {
                    isWorking = false
                    notice = EditorNotice(
                        title: language.text("gestalt.error_title"),
                        message: localized(error)
                    )
                }
            }
        }
    }

    private func localized(_ error: Error) -> String {
        if let error = error as? MobileGestaltError {
            return language.text(error.localizationKey)
        }
        return error.localizedDescription
    }
}