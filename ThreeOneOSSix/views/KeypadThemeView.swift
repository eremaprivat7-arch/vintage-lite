import SwiftUI
import UniformTypeIdentifiers

struct KeypadThemeView: View {
    @Environment(\.appLanguage) private var language

    @State private var isLoading = true
    @State private var isWorking = false
    @State private var state: KeypadThemeState?
    @State private var images: [KeypadKey: Data] = [:]
    @State private var selectedKey: KeypadKey?
    @State private var showImporter = false
    @State private var errorMessage: String?
    @State private var showApplyConfirmation = false
    @State private var showResetConfirmation = false
    @State private var notice: KeypadNotice?

    private struct KeypadNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 10),
        count: 3
    )

    var body: some View {
        Form {
            Section {
                Text(language.text("keypad.safety"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if isLoading {
                Section {
                    HStack {
                        ProgressView()
                        Text(language.text("keypad.loading"))
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
                Section {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(KeypadKey.allCases) { key in
                            Button {
                                selectedKey = key
                                showImporter = true
                            } label: {
                                keyCell(key)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(language.text("keypad.section.keys"))
                } footer: {
                    if let state {
                        Text(language.text("keypad.path_footer", state.telephonyPath))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        showApplyConfirmation = true
                    } label: {
                        Label(language.text("keypad.apply"), systemImage: "checkmark.seal.fill")
                    }
                    .disabled(isWorking || images.isEmpty)

                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Label(language.text("keypad.reset"), systemImage: "arrow.counterclockwise")
                    }
                    .disabled(isWorking)
                } footer: {
                    Text(language.text("keypad.footer"))
                }
            }
        }
        .navigationTitle(language.text("keypad.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            importImage(result)
        }
        .alert(language.text("keypad.apply_confirm_title"), isPresented: $showApplyConfirmation) {
            Button(language.text("keypad.apply"), role: .destructive) {
                apply()
            }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("keypad.apply_confirm_message"))
        }
        .alert(language.text("keypad.reset_confirm_title"), isPresented: $showResetConfirmation) {
            Button(language.text("keypad.reset"), role: .destructive) {
                reset()
            }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("keypad.reset_confirm_message"))
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

    private func keyCell(_ key: KeypadKey) -> some View {
        VStack(spacing: 6) {
            if let data = images[key], let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .frame(height: 56)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
            Text(key.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(uiColor: .secondarySystemBackground).opacity(0.5))
        )
    }

    private func load() {
        isLoading = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let loaded = try KeypadThemeService.load()
                DispatchQueue.main.async {
                    state = loaded
                    images = loaded.images
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

    private func importImage(_ result: Result<[URL], Error>) {
        guard let key = selectedKey else { return }
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            guard UIImage(data: data) != nil else {
                throw KeypadThemeError.imageInvalid
            }
            images[key] = data
        } catch {
            notice = KeypadNotice(
                title: language.text("keypad.error_title"),
                message: error.localizedDescription
            )
        }
    }

    private func apply() {
        guard !images.isEmpty else { return }
        isWorking = true
        let payload = images
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try KeypadThemeService.apply(images: payload)
                DispatchQueue.main.async {
                    isWorking = false
                    notice = KeypadNotice(
                        title: language.text("keypad.applied_title"),
                        message: language.text("keypad.applied_message")
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    isWorking = false
                    notice = KeypadNotice(
                        title: language.text("keypad.error_title"),
                        message: localized(error)
                    )
                }
            }
        }
    }

    private func reset() {
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try KeypadThemeService.reset()
                DispatchQueue.main.async {
                    isWorking = false
                    notice = KeypadNotice(
                        title: language.text("keypad.reset_done_title"),
                        message: language.text("keypad.reset_done_message")
                    )
                    load()
                }
            } catch {
                DispatchQueue.main.async {
                    isWorking = false
                    notice = KeypadNotice(
                        title: language.text("keypad.error_title"),
                        message: localized(error)
                    )
                }
            }
        }
    }

    private func localized(_ error: Error) -> String {
        if let error = error as? KeypadThemeError {
            return language.text(error.localizationKey)
        }
        return error.localizedDescription
    }
}