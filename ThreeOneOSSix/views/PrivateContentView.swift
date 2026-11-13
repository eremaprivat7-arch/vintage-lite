import SwiftUI

struct PrivateContentView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var license: LicenseSession
    @EnvironmentObject private var store: PatchProjectStore
    @EnvironmentObject private var draftCoordinator: PatchDraftCoordinator
    @State private var assets: [PrivateContentAsset] = []
    @State private var category: VintageCategory = .boost
    @State private var search = ""
    @State private var showCreate = false
    @State private var busy = false
    @State private var message = ""
    @State private var restoreRequested = false
    @State private var confirm = false
    @State private var hasCatalog = false

    private var query: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var remoteItems: [PrivateContentAsset] {
        assets.filter { $0.category == category.rawValue }
    }

    private var localItems: [PatchLibraryItem] {
        store.items.filter { $0.vintageCategory == category }
    }

    private var matchingRemote: [PrivateContentAsset] {
        query.isEmpty ? remoteItems : remoteItems.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var matchingLocal: [PatchLibraryItem] {
        guard !query.isEmpty else { return localItems }
        return localItems.filter { item in
            let fields = [item.project?.name, item.packageURL.lastPathComponent].compactMap { $0 }
            return fields.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        List {
            banner
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.black)

            Picker("Раздел", selection: $category) {
                ForEach(VintageCategory.allCases, id: \.self) { section in
                    Text(verbatim: section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.black)

            AppSearchField(text: $search, prompt: language.text("patch.search"),
                           clearLabel: language.text("common.clear"))
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.black)

            if !message.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                    if !hasCatalog {
                        Button("Повторить") { Task { await refresh() } }.disabled(busy)
                    }
                }
                .listRowSeparator(.hidden)
            }

            ForEach(matchingRemote) { asset in
                NavigationLink {
                    remoteDetail(asset)
                } label: {
                    fileRow(title: asset.title, subtitle: "Защищённый файл", icon: category.icon)
                }
                .listRowBackground(cardBackground)
                .listRowSeparator(.hidden)
            }

            ForEach(matchingLocal) { item in
                localRow(item)
                    .listRowBackground(cardBackground)
                    .listRowSeparator(.hidden)
            }
            .onDelete { offsets in
                let items = matchingLocal
                for index in offsets { store.delete(items[index]) }
            }

            if matchingRemote.isEmpty && matchingLocal.isEmpty {
                if busy || store.isBusy || (!hasCatalog && message.isEmpty) {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                        .listRowSeparator(.hidden)
                } else if !localItems.isEmpty || !remoteItems.isEmpty {
                    emptyRow(language.text("patch.search_empty"), icon: "magnifyingglass")
                        .listRowSeparator(.hidden)
                } else if hasCatalog {
                    emptyRow("В разделе \(category.rawValue) пока нет файлов", icon: "shippingbox")
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("VINTAGE LITE")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(language.text("patch.new"))
                    .disabled(store.isBusy)
            }
        }
        .sheet(isPresented: $showCreate) {
            PatchProjectEditorView(existingProject: nil, passwordIsProtected: false) { project, password in
                store.create(project: project, password: password, category: category)
            }
        }
        .sheet(item: $draftCoordinator.request) { request in
            PatchProjectEditorView(existingProject: nil, passwordIsProtected: false, initialDraft: request.draft) { project, password in
                store.create(project: project, password: password, category: category)
                draftCoordinator.clear()
            }
        }
        .alert(item: $store.alert) { alert in
            Alert(title: Text(language.text(alert.titleKey)),
                  message: Text(alert.message(language: language)),
                  dismissButton: .default(Text(language.text("common.ok"))))
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .onAppear { consumeImport() }
        .onChange(of: draftCoordinator.importRequest?.id) { _ in consumeImport() }
    }

    private var banner: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geometry in
                Image("VintageSky").resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped().accessibilityHidden(true)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 7) {
                Text("VINTAGE LITE").font(.caption.weight(.bold)).tracking(3)
                Text(category.rawValue.uppercased()).font(.largeTitle.weight(.black))
            }
            .foregroundStyle(.white).padding(18)
        }
        .frame(height: 165)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 19)
            .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.08)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 19).stroke(.white.opacity(0.16)))
            .padding(.horizontal, 6).padding(.vertical, 4)
    }

    private func fileRow(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2.weight(.bold)).foregroundStyle(.black)
                .frame(width: 48, height: 48)
                .background(LinearGradient(colors: [.white, Color(white: 0.66)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func localRow(_ item: PatchLibraryItem) -> some View {
        let name = item.project?.name ?? item.packageURL.deletingPathExtension().lastPathComponent
        if item.isLocked {
            Button { store.requestUnlock(for: item) } label: {
                fileRow(title: name, subtitle: language.text("patch.tap_to_unlock"), icon: "lock.fill")
            }.buttonStyle(.plain)
        } else {
            NavigationLink {
                PatchProjectDetailView(store: store, projectID: item.id)
            } label: {
                let count = (item.project?.rules.count ?? 0) + (item.project?.directories.count ?? 0)
                let subtitle = language.text(item.summary.schemaVersion >= 2 ? "patch.workspace_items_count" : "patch.rules_count",
                                             Int64(count))
                fileRow(title: name, subtitle: subtitle, icon: category.icon)
            }
        }
    }

    private func emptyRow(_ title: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: AppTheme.emptyIconSize, weight: .light))
            Text(title).font(.headline).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 64)
    }

    private func remoteDetail(_ asset: PrivateContentAsset) -> some View {
        let applied = UUID(uuidString: asset.package_id).flatMap {
            DevicePatchService.latestReceipt(projectID: $0)
        } != nil
        return List {
            Section {
                LabeledContent("Раздел", value: asset.category)
                LabeledContent("Размер", value: ByteCountFormatter.string(fromByteCount: Int64(asset.size), countStyle: .file))
            }
            Section {
                Button {
                    restoreRequested = false
                    confirm = true
                } label: {
                    Label("Применить", systemImage: "bolt.fill")
                        .font(.headline.bold()).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14))
                }.disabled(busy || applied)
                if applied {
                    Button(role: .destructive) {
                        restoreRequested = true
                        confirm = true
                    } label: { Label("Восстановить", systemImage: "arrow.uturn.backward.circle") }
                    .disabled(busy)
                }
            }
            if busy { ProgressView() }
            if !message.isEmpty { Text(message).font(.subheadline).foregroundStyle(.secondary) }
        }
        .navigationTitle(asset.title)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(restoreRequested ? "Восстановить оригинальные файлы?" : "Применить выбранный файл?",
                            isPresented: $confirm, titleVisibility: .visible) {
            Button(restoreRequested ? "Восстановить" : "Применить") {
                let restore = restoreRequested
                Task { await perform(asset, restore: restore) }
            }
            Button("Отмена", role: .cancel) {}
        } message: { Text(asset.title) }
    }

    private func consumeImport() {
        guard let request = draftCoordinator.importRequest else { return }
        draftCoordinator.clearImport()
        category = .boost
        search = ""
        store.importPackage(from: request.source)
    }

    @MainActor private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            assets = try await PrivateContentClient.shared.catalog(license.contentCredentials())
            hasCatalog = true
            message = ""
        } catch {
            guard !Task.isCancelled else { return }
            message = error.localizedDescription
        }
    }

    @MainActor private func perform(_ asset: PrivateContentAsset, restore: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
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
