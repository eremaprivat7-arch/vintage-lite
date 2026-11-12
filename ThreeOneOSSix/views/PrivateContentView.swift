import SwiftUI

struct PrivateContentView: View {
    @EnvironmentObject private var license: LicenseSession
    @State private var assets: [PrivateContentAsset] = []
    @State private var category = "Boost"
    @State private var busy = false
    @State private var message = ""
    @State private var selected: PrivateContentAsset?
    @State private var restoring = false
    @State private var confirm = false
    private let categories = ["Boost", "Mod Skin", "FPS", "Holo"]

    var body: some View {
        List {
            Section {
                Picker("Раздел", selection: $category) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
            }
            if !message.isEmpty {
                Section { Text(message).font(.subheadline).foregroundStyle(.secondary) }
            }
            Section(category) {
                ForEach(assets.filter { $0.category == category }) { asset in
                    HStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill").foregroundStyle(.mint)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(asset.title).font(.headline)
                            Text("Защищённый файл").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Применить") { selected = asset; restoring = false; confirm = true }
                            .buttonStyle(.bordered)
                        if let id = UUID(uuidString: asset.package_id), DevicePatchService.latestReceipt(projectID: id) != nil {
                            Button { selected = asset; restoring = true; confirm = true } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }.buttonStyle(.borderless).accessibilityLabel("Восстановить оригинал")
                        }
                    }.padding(.vertical, 6)
                }
                if !busy && assets.filter({ $0.category == category }).isEmpty {
                    Text("В этом разделе пока нет файлов.").foregroundStyle(.secondary)
                }
            }
        }
        .disabled(busy)
        .navigationTitle("Файлы VintageLite")
        .toolbar { Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(busy) }
        .overlay { if busy { ProgressView().padding(20).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .task { await refresh() }
        .refreshable { await refresh() }
        .confirmationDialog(restoring ? "Восстановить оригинальные файлы?" : "Применить выбранный файл?", isPresented: $confirm) {
            Button(restoring ? "Восстановить" : "Применить") {
                if let selected { Task { await perform(selected, restore: restoring) } }
            }
            Button("Отмена", role: .cancel) { selected = nil }
        } message: { Text(selected?.title ?? "") }
    }

    @MainActor private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            assets = try await PrivateContentClient.shared.catalog(license.contentCredentials())
            message = ""
        } catch { message = error.localizedDescription }
    }

    @MainActor private func perform(_ asset: PrivateContentAsset, restore: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false; selected = nil }
        do {
            guard await license.checkForApply() else { return }
            if restore {
                guard let id = UUID(uuidString: asset.package_id), let receipt = DevicePatchService.latestReceipt(projectID: id) else { return }
                try await Task.detached(priority: .userInitiated) { try DevicePatchService.restore(receipt: receipt) }.value
                message = "Оригинальные файлы восстановлены."
            } else {
                let project = try await PrivateContentClient.shared.project(asset, credentials: license.contentCredentials())
                guard await license.checkForApply() else { return }
                _ = try await Task.detached(priority: .userInitiated) { try DevicePatchService.apply(project: project) }.value
                message = "Файл применён."
            }
        } catch PatchPackageError.projectAlreadyApplied {
            message = "Этот файл уже применён. Для повторного применения сначала восстанови оригинал."
        } catch { message = (error as? PrivateContentError)?.localizedDescription ?? "Не удалось применить изменение. Проверь доступ к приложению и выбранный файл." }
    }
}
