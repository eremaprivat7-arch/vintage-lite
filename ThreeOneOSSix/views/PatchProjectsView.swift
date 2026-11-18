import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum PatchPackagePickerPolicy {
    // Export uses the new .3106 extension; .3105 stays importable so existing
    // patch repositories keep working.
    static let packageType = UTType(filenameExtension: "3106")
        ?? UTType(filenameExtension: "3105")
        ?? .data
    static let allowedContentTypes: [UTType] = [packageType, .data]
    static let copiesSelectedDocument = true
}

private enum WallpaperPackagePickerPolicy {
    static let packageType = UTType(filenameExtension: "tendies") ?? .data
    static let allowedContentTypes: [UTType] = [packageType, .data]
}

struct PatchProjectsView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var draftCoordinator: PatchDraftCoordinator
    @EnvironmentObject private var store: PatchProjectStore
    @AppStorage(FeatureVisibility.cleanerStorageKey) private var cleanerEnabled = true
    @State private var showCreate = false
    @State private var showImporter = false
    @State private var showWallpaperImporter = false
    @State private var showCleaner = false
    @State private var searchText = ""
    @State private var wallpaperPackages: [WallpaperStagedPackage] = []
    @State private var wallpaperImportFeedback: WallpaperImportFeedback?
    @State private var wallpaperPendingDeletion: WallpaperStagedPackage?
    @State private var isImportingWallpapers = false
    @State private var showSimulatedWallpaperDetail = false
    @State private var simulatedWallpaperDetailGate = OneShotPresentationGate()
    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void

    private var filteredItems: [PatchLibraryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.items }
        return store.items.filter { item in
            if item.displayName.localizedCaseInsensitiveContains(query) { return true }
            if item.packageURL.lastPathComponent.localizedCaseInsensitiveContains(query) {
                return true
            }
            guard let project = item.project else { return false }
            if project.name.localizedCaseInsensitiveContains(query)
                || project.author.localizedCaseInsensitiveContains(query) {
                return true
            }
            guard item.canInspectContents else { return false }
            return project.allBundleIdentifiers.contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
                || project.directories.contains {
                    $0.relativePath.localizedCaseInsensitiveContains(query)
                }
                || project.rules.contains {
                    $0.relativePath.localizedCaseInsensitiveContains(query)
                        || $0.replacementFilename.localizedCaseInsensitiveContains(query)
                }
        }
    }

    private var filteredWallpaperPackages: [WallpaperStagedPackage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return wallpaperPackages }
        return wallpaperPackages.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private var hasLocalContent: Bool {
        !store.items.isEmpty || !wallpaperPackages.isEmpty
    }

    private var hasSearchResults: Bool {
        !filteredItems.isEmpty || !filteredWallpaperPackages.isEmpty
    }

    init(
        onOpenSettings: @escaping () -> Void = {},
        onOpenLogs: @escaping () -> Void = {}
    ) {
        self.onOpenSettings = onOpenSettings
        self.onOpenLogs = onOpenLogs
#if targetEnvironment(simulator)
        _showCreate = State(
            initialValue: ProcessInfo.processInfo.arguments.contains("--simulate-patch-editor")
        )
#endif
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppSearchField(
                    text: $searchText,
                    prompt: language.text("installed.search"),
                    clearLabel: language.text("common.clear")
                )
                Divider()
                List {
                    if !hasLocalContent && (store.isBusy || isImportingWallpapers) {
                        loadingState
                            .listRowSeparator(.hidden)
                    } else if !hasLocalContent {
                        emptyState
                            .listRowSeparator(.hidden)
                    } else if !hasSearchResults && !store.isBusy {
                        searchEmptyState
                            .listRowSeparator(.hidden)
                    } else {
                        if !filteredItems.isEmpty {
                            Section(language.text("patch.title")) {
                                ForEach(filteredItems) { item in
                                    itemRow(item).deleteDisabled(item.isBundled)
                                }
                                .onDelete { offsets in
                                    offsets.map { filteredItems[$0] }.filter { !$0.isBundled }.forEach(store.delete)
                                }
                            }
                        }
                        if !filteredWallpaperPackages.isEmpty {
                            Section(language.text("tab.wallpapers")) {
                                ForEach(filteredWallpaperPackages) { package in
                                    NavigationLink {
                                        InstalledWallpaperPackageDetailView(
                                            package: package,
                                            onApplied: reloadWallpaperPackages
                                        )
                                    } label: {
                                        wallpaperRow(package)
                                    }
                                    .swipeActions(
                                        edge: .trailing,
                                        allowsFullSwipe: false
                                    ) {
                                        Button(role: .destructive) {
                                            wallpaperPendingDeletion = package
                                        } label: {
                                            Label(
                                                language.text("common.delete"),
                                                systemImage: "trash"
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if cleanerEnabled {
                        Section(language.text("repository.utilities")) {
                            cleanerRow
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle(language.text("tab.installed"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showCreate = true
                        } label: {
                            Label(language.text("patch.new"), systemImage: "doc.badge.plus")
                        }
                        Button {
                            showImporter = true
                        } label: {
                            Label(language.text("patch.import"), systemImage: "square.and.arrow.down")
                        }
                        Button {
                            showWallpaperImporter = true
                        } label: {
                            Label(
                                language.text("wallpaper.import"),
                                systemImage: "photo.badge.plus"
                            )
                        }
                    } label: {
                        if store.isBusy || isImportingWallpapers {
                            ProgressView()
                        } else {
                            Image(systemName: "plus")
                        }
                    }
                    .disabled(store.isBusy || isImportingWallpapers)
                    .accessibilityLabel(language.text("patch.add"))
                }
                AppUtilityToolbar(
                    language: language,
                    onOpenSettings: onOpenSettings,
                    onOpenLogs: onOpenLogs
                )
            }
            .sheet(isPresented: $showImporter) {
                FileDocumentPicker(
                    allowedContentTypes: PatchPackagePickerPolicy.allowedContentTypes,
                    copiesSelectedDocument: PatchPackagePickerPolicy.copiesSelectedDocument,
                    allowsMultipleSelection: false,
                    onSelection: { result in
                        showImporter = false
                        if case .success(let urls) = result, let url = urls.first {
                            store.importPackage(at: url)
                        }
                    },
                    onCancel: {
                        showImporter = false
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showCreate) {
                PatchProjectEditorView(
                    existingProject: nil,
                    passwordIsProtected: false
                ) { project, password in
                    store.create(project: project, password: password)
                }
            }
            .sheet(isPresented: $showCleaner) {
                CleanerView()
            }
            .sheet(item: $draftCoordinator.request) { request in
                PatchProjectEditorView(
                    existingProject: nil,
                    passwordIsProtected: false,
                    initialDraft: request.draft
                ) { project, password in
                    store.create(project: project, password: password)
                    draftCoordinator.clear()
                }
            }
            .sheet(isPresented: $showWallpaperImporter) {
                FileDocumentPicker(
                    allowedContentTypes: WallpaperPackagePickerPolicy.allowedContentTypes,
                    copiesSelectedDocument: true,
                    allowsMultipleSelection: true,
                    onSelection: { result in
                        showWallpaperImporter = false
                        if case .success(let urls) = result, !urls.isEmpty {
                            importWallpaperPackages(urls)
                        }
                    },
                    onCancel: {
                        showWallpaperImporter = false
                    }
                )
                .ignoresSafeArea()
            }
            .alert(item: $wallpaperImportFeedback) { feedback in
                Alert(
                    title: Text(language.text(feedback.titleKey)),
                    message: Text(feedback.message),
                    dismissButton: .default(Text(language.text("common.ok")))
                )
            }
            .alert(item: $wallpaperPendingDeletion) { package in
                Alert(
                    title: Text(language.text("wallpaper.delete_title")),
                    message: Text(language.text(
                        "wallpaper.delete_message",
                        package.displayName
                    )),
                    primaryButton: .destructive(
                        Text(language.text("common.delete"))
                    ) {
                        deleteWallpaperPackage(package)
                    },
                    secondaryButton: .cancel(Text(language.text("common.cancel")))
                )
            }
            .onAppear {
                reloadWallpaperPackages()
                consumeExternalImport()
#if targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains(
                    "--simulate-wallpaper-detail"
                ), !wallpaperPackages.isEmpty,
                   simulatedWallpaperDetailGate.claim() {
                    DispatchQueue.main.async {
                        showSimulatedWallpaperDetail = true
                    }
                }
#endif
            }
            .navigationDestination(isPresented: $showSimulatedWallpaperDetail) {
                if let package = wallpaperPackages.first {
                    InstalledWallpaperPackageDetailView(
                        package: package,
                        onApplied: reloadWallpaperPackages
                    )
                }
            }
            .onChange(of: draftCoordinator.importRequest?.id) { _ in
                consumeExternalImport()
            }
        }
    }

    private func consumeExternalImport() {
        guard let request = draftCoordinator.importRequest else { return }
        draftCoordinator.clearImport()
        store.importPackage(from: request.source)
    }

    private func wallpaperRow(_ package: WallpaperStagedPackage) -> some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: wallpaperSymbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(package.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                InstalledContentKindBadge(kind: .wallpaper, language: language)
                Text(language.text(
                    "wallpaper.package_summary",
                    Int64(package.payload.descriptors.count),
                    ByteCountFormatter.string(
                        fromByteCount: package.payload.totalBytes,
                        countStyle: .file
                    )
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var cleanerRow: some View {
        Button {
            showCleaner = true
        } label: {
            HStack(spacing: 12) {
                AppRowIcon(systemName: "sparkles")
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text("tab.cleaner"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(language.text("repository.cleaner_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var wallpaperSymbol: String {
        if #available(iOS 18.0, *) {
            return "photo.on.rectangle.angled.fill"
        }
        return "photo.fill.on.rectangle.fill"
    }

    private func reloadWallpaperPackages() {
        wallpaperPackages = WallpaperPackageStore.packages()
    }

    private func deleteWallpaperPackage(_ package: WallpaperStagedPackage) {
        do {
            try WallpaperPackageStore.delete(package)
            reloadWallpaperPackages()
        } catch {
            wallpaperImportFeedback = WallpaperImportFeedback(
                titleKey: "wallpaper.operation_failed",
                message: wallpaperErrorMessage(error)
            )
        }
    }

    private func importWallpaperPackages(_ urls: [URL]) {
        guard !isImportingWallpapers else { return }
        isImportingWallpapers = true
        DispatchQueue.global(qos: .userInitiated).async {
            var imported = 0
            var failures: [String] = []
            for url in urls {
                do {
                    _ = try WallpaperPackageStore.importPackage(from: url)
                    imported += 1
                    log("wallpaper: staged \(url.lastPathComponent)")
                } catch {
                    failures.append(
                        "\(url.lastPathComponent): \(wallpaperErrorMessage(error))"
                    )
                    log("wallpaper: import rejected \(url.lastPathComponent)")
                }
            }
            DispatchQueue.main.async {
                isImportingWallpapers = false
                reloadWallpaperPackages()
                wallpaperImportFeedback = WallpaperImportFeedback(
                    titleKey: failures.isEmpty
                        ? "wallpaper.import_done_title"
                        : "wallpaper.import_result_title",
                    message: failures.isEmpty
                        ? language.text(
                            "wallpaper.import_done_message",
                            Int64(imported)
                        )
                        : failures.joined(separator: "\n")
                )
            }
        }
    }

    private func wallpaperErrorMessage(_ error: Error) -> String {
        if let wallpaperError = error as? WallpaperLabError {
            return language.text(wallpaperError.localizationKey)
        }
        return language.text("wallpaper.error.unknown")
    }

    @ViewBuilder
    private func itemRow(_ item: PatchLibraryItem) -> some View {
        if item.isLocked {
            Button { store.requestUnlock(for: item) } label: {
                PatchProjectRow(item: item, language: language)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                PatchProjectDetailView(store: store, projectID: item.id)
            } label: {
                PatchProjectRow(item: item, language: language)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(AppTheme.accent)
            Text(language.text("installed.empty_title"))
                .font(.headline)
            Text(language.text("installed.empty_message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(language.text("patch.new")) { showCreate = true }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(language.text("installed.loading"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(.secondary)
            Text(language.text("patch.search_empty"))
                .font(.headline)
            Text(language.text("patch.search_empty_message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }
}

private struct WallpaperImportFeedback: Identifiable {
    let id = UUID()
    let titleKey: String
    let message: String
}

private struct PatchProjectRow: View {
    let item: PatchLibraryItem
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: item.isLocked ? "lock.doc.fill" : "shippingbox.fill")
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                InstalledContentKindBadge(kind: .patch, language: language)
                if let author = item.project?.author, !author.isEmpty {
                    Text(language.text("patch.by_author", author))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(rowDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.summary.isPasswordProtected {
                Image(systemName: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(language.text("patch.password_protected"))
            }
            if item.project?.isPrivate == true {
                Image(systemName: "eye.slash.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityLabel(language.text("patch.private"))
            }
        }
        .padding(.vertical, 4)
    }

    private var rowDetail: String {
        if item.isLocked {
            return language.text("patch.tap_to_unlock")
        }
        if item.project?.isPrivate == true, !item.isAuthorCopy {
            return language.text("patch.private_received")
        }
        return language.text(
            item.summary.schemaVersion >= 2
                ? "patch.workspace_items_count"
                : "patch.rules_count",
            Int64((item.project?.rules.count ?? 0) + (item.project?.directories.count ?? 0))
        )
    }
}

private enum InstalledContentKind {
    case patch
    case wallpaper

    var localizationKey: String {
        switch self {
        case .patch: return "installed.kind.patch"
        case .wallpaper: return "installed.kind.wallpaper"
        }
    }

    var systemImage: String {
        switch self {
        case .patch: return "shippingbox.fill"
        case .wallpaper: return "photo.fill"
        }
    }
}

private struct InstalledContentKindBadge: View {
    let kind: InstalledContentKind
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.systemImage)
                .accessibilityHidden(true)
            Text(language.text(kind.localizationKey))
        }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(AppTheme.accent.opacity(0.12), in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .combine)
    }
}

struct PatchUnlockView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PatchProjectStore
    let request: PatchPasswordRequest
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(language.text("patch.password"), text: $password)
                        .textContentType(.password)
                        .submitLabel(.done)
                        .onSubmit(unlock)
                        .onChange(of: password) { _ in
                            store.clearUnlockError()
                        }
                    if let errorKey = store.unlockErrorKey {
                        Text(language.text(errorKey))
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    if let origin = request.origin {
                        Text(language.text(
                            "patch.password_repo_contact",
                            origin.repositoryName
                        ))
                    } else {
                        Text(language.text("patch.password_once_message"))
                    }
                }
            }
            .navigationTitle(language.text("patch.unlock"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("patch.unlock"), action: unlock)
                        .disabled(password.isEmpty || store.isBusy)
                }
            }
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        store.unlock(password: password)
    }
}

private struct PatchStorePresentationModifier: ViewModifier {
    @ObservedObject var store: PatchProjectStore

    func body(content: Content) -> some View {
        content
            .sheet(item: $store.passwordRequest, onDismiss: store.cancelUnlock) { request in
                PatchUnlockView(store: store, request: request)
            }
    }
}

extension View {
    func patchStorePresentation(_ store: PatchProjectStore) -> some View {
        modifier(PatchStorePresentationModifier(store: store))
    }
}

private struct VintagePatchToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 14) {
                configuration.label
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                Text(configuration.isOn ? "ON" : "OFF")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(configuration.isOn ? Color.white : Color.white.opacity(0.45))
                    .frame(width: 32)
                Capsule()
                    .fill(configuration.isOn ? Color.white : Color(white: 0.24))
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Capsule()
                            .fill(.white)
                            .overlay(Capsule().stroke(.black.opacity(0.07), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
                            .frame(width: 46, height: 30)
                            .padding(4)
                    }
                    .frame(width: 84, height: 38)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(configuration.isOn ? "ON" : "OFF"))
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: configuration.isOn)
    }
}

struct PatchProjectDetailView: View {
    @EnvironmentObject private var license: LicenseSession
    @EnvironmentObject private var appState: AppState
    @Environment(\.appLanguage) private var language
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var store: PatchProjectStore
    let projectID: UUID
    @State private var showEditor = false
    @State private var editingRule: PatchRule?
    @State private var showChangedRestoreConfirmation = false
    @State private var restoreChangedPaths: [String] = []
    @State private var isWorking = false
    @State private var applyProgress: PatchApplyProgress = .checkingLicense
    @State private var operationStarted = Date()
    @State private var progressID: UUID?
    @State private var actionAlert: PatchStoreAlert?
    @State private var showRecovery = false
    @State private var recoveryWorking = false
    @State private var receipt: PatchTransactionReceipt?

    private var item: PatchLibraryItem? {
        store.items.first(where: { $0.id == projectID })
    }

    private var isWorkspaceProject: Bool {
        (item?.summary.schemaVersion ?? 1) >= 2
    }

    var body: some View {
        List {
            if let item, let project = item.project {
                if project.isPrivate && !item.canInspectContents && !item.isBundled {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(AppTheme.accent)
                            Text(language.text("patch.private_hidden_title"))
                                .font(.headline)
                            Text(language.text("patch.private_hidden_message"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                } else if isWorkspaceProject {
                    Section {
                        ForEach(project.allBundleIdentifiers, id: \.self) { bundleID in
                            Label {
                                Text(bundleID)
                                    .font(.subheadline.monospaced())
                            } icon: {
                                Image(systemName: "app.dashed")
                                    .foregroundStyle(AppTheme.accent)
                            }
                        }
                        LabeledContent(language.text("patch.files")) {
                            Text("\(project.rules.count)")
                        }
                        LabeledContent(language.text("patch.folders")) {
                            Text("\(project.directories.count)")
                        }
                        if let workspaceURL = item.workspaceURL {
                            NavigationLink {
                                FileBrowserView(
                                    containerPath: workspaceURL.path,
                                    title: item.displayName,
                                    bundleID: nil
                                )
                            } label: {
                                Label(
                                    language.text("patch.open_workspace"),
                                    systemImage: "folder"
                                )
                            }
                        }
                    } header: {
                        Text(language.text("patch.workspace"))
                    } footer: {
                        Text(language.text("patch.workspace_detail_footer"))
                    }
                } else if item.canInspectContents {
                    Section {
                        ForEach(project.rules) { rule in
                            Button {
                                editingRule = rule
                            } label: {
                                HStack(spacing: 10) {
                                    ruleSummary(rule)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(language.text("patch.edit_rule_hint"))
                        }
                    } header: {
                        Text(language.text("patch.rules"))
                    } footer: {
                        Text(language.text("patch.legacy_footer"))
                    }
                }

                Section(language.text("patch.password")) {
                    HStack(spacing: 12) {
                        Image(systemName: item.summary.isPasswordProtected ? "lock.fill" : "lock.open")
                            .foregroundStyle(AppTheme.accent)
                            .frame(width: 24)
                        Text(language.text(item.summary.isPasswordProtected
                            ? "patch.password_locked"
                            : "patch.no_password"))
                            .font(.subheadline)
                    }
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { receipt != nil },
                        set: { setPatchEnabled($0) }
                    )) {
                        Text(language.text("patch.toggle.title"))
                            .font(.headline)
                    }
                    .toggleStyle(VintagePatchToggleStyle())
                    .disabled(isWorking || store.isBusy || store.isPatchOperationRunning || appState.kernelExploitRunning)
                    .accessibilityIdentifier("patch.power")
                    .accessibilityHint(language.text("patch.toggle.hint"))

                    if store.isPatchOperationRunning && !isWorking {
                        ProgressView(language.text("patch.toggle.busy"))
                    }

                    if appState.kernelExploitRunning && !isWorking {
                        ProgressView(language.text("patch.progress.device_access"))
                    }

                    if isWorking {
                        ProgressView(progressText)
                        TimelineView(.periodic(from: operationStarted, by: 1)) { context in
                            let seconds = max(0, Int(context.date.timeIntervalSince(operationStarted)))
                            Text(language.text("patch.progress.elapsed",
                                               String(format: "%02d:%02d", seconds / 60, seconds % 60)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                } footer: {
                    Text(language.text("patch.toggle.hint"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item?.displayName ?? language.text("patch.title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isWorking)
        .interactiveDismissDisabled(isWorking)
        .onAppear(perform: refreshReceipt)
        .onChange(of: store.isPatchOperationRunning) { running in
            if !running { refreshReceipt() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active && !store.isPatchOperationRunning { refreshReceipt() }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isWorking {
                    ProgressView()
                } else if !isWorkspaceProject, item?.canInspectContents == true {
                    Button(language.text("patch.edit")) { showEditor = true }
                        .disabled(item?.project == nil)
                }
            }
        }
        .sheet(isPresented: $showRecovery) {
            NavigationStack {
                AppliedPatchRecoveryView(store: store, isWorking: $recoveryWorking, conflictingProject: item?.project)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(language.text("common.done")) { showRecovery = false }
                                .disabled(recoveryWorking)
                        }
                    }
            }
        }
        .sheet(isPresented: $showEditor) {
            if let item, let project = item.project {
                PatchProjectEditorView(
                    existingProject: project,
                    passwordIsProtected: item.summary.isPasswordProtected
                ) { updatedProject, _ in
                    store.update(project: updatedProject)
                }
            }
        }
        .sheet(item: $editingRule) { rule in
            PatchRuleEditorView(rule: rule) { updatedRule in
                updateRule(updatedRule)
            }
        }
        .confirmationDialog(
            language.text("patch.restore_changed_title"),
            isPresented: $showChangedRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("patch.restore_changed_action"), role: .destructive) {
                restore(allowChangedTargets: true)
            }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(changedRestoreMessage)
        }
        .alert(item: $actionAlert) { alert in
            if alert.messageKey == "patch.error.target_busy" {
                return Alert(
                    title: Text(language.text(alert.titleKey)),
                    message: Text(alert.message(language: language)),
                    primaryButton: .default(Text(language.text("patch.recovery.open"))) { showRecovery = true },
                    secondaryButton: .cancel(Text(language.text("common.cancel")))
                )
            }
            return Alert(
                title: Text(language.text(alert.titleKey)),
                message: Text(alert.message(language: language)),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
    }

    private func refreshReceipt() {
        // A receipt remains active until restoration succeeds, including recovery.
        receipt = DevicePatchService.latestReceipt(projectID: projectID)
    }

    @MainActor
    private func setPatchEnabled(_ enabled: Bool) {
        guard !isWorking, !store.isBusy, !store.isPatchOperationRunning,
              !appState.kernelExploitRunning, enabled != (receipt != nil) else { return }
        if enabled { apply() } else { prepareRestore() }
    }

    private func ruleSummary(_ rule: PatchRule) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(rule.bundleID)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(rule.relativePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Label(rule.replacementFilename, systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(AppTheme.accent)
        }
        .padding(.vertical, 3)
    }

    private func updateRule(_ updatedRule: PatchRule) {
        guard var project = item?.project,
              let index = project.rules.firstIndex(where: { $0.id == updatedRule.id }) else {
            return
        }
        project.rules[index] = updatedRule
        project.updatedAt = Date()
        do {
            try PatchPackageCodec.validate(project)
            store.update(project: project)
        } catch let error as PatchPackageError {
            actionAlert = PatchStoreAlert(
                titleKey: "common.failed",
                messageKey: error.localizationKey,
                messageArgument: error.localizationArgument
            )
        } catch {
            actionAlert = PatchStoreAlert(
                titleKey: "common.failed",
                messageKey: "patch.error.invalid_project"
            )
        }
    }

    private var progressText: String {
        switch applyProgress {
        case .checkingLicense: return language.text("patch.progress.license")
        case .preparingWorkspace: return language.text("patch.progress.workspace")
        case .resolvingApp: return language.text("patch.progress.resolve")
        case .checkingFiles: return language.text("patch.progress.validate")
        case .backingUp: return language.text("patch.progress.backup")
        case .writingFile(let current, let total):
            return language.text("patch.progress.write", Int64(current), Int64(total))
        case .finishing: return language.text("patch.progress.finish")
        case .restoring: return language.text("patch.progress.restore")
        }
    }

    @MainActor
    private func apply() {
        guard !isWorking, let item, let baseProject = item.project else { return }
        log("patch: preflight iOS=\(AppInfo.osVersion) build=\(AppInfo.osBuild) backend=\(SandboxAccess.backend.displayName) setup=\(appState.exploitStatus.displayText) appGroup=\(SandboxAccess.hasAppGroup)")
        guard !appState.kernelExploitRunning else {
            actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.access_initializing")
            return
        }
        do {
            try DevicePatchService.validateAccess()
        } catch let error as PatchPackageError {
            actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: error.localizationKey)
            return
        } catch {
            actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.access_unavailable")
            return
        }

        guard store.beginPatchOperation() else { return }
        let attempt = UUID()
        progressID = attempt
        isWorking = true
        operationStarted = Date()
        applyProgress = .checkingLicense
        log("patch: apply started id=\(projectID) backend=\(SandboxAccess.backend.displayName)")

        Task {
            defer {
                refreshReceipt()
                progressID = nil
                isWorking = false
                store.endPatchOperation()
            }
            guard await license.checkForApply() else {
                log("patch: apply stopped by license or maintenance check")
                actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.license_check")
                return
            }

            let report: @Sendable (PatchApplyProgress) -> Void = { stage in
                log("patch: apply stage \(stage)")
                Task { @MainActor in
                    guard progressID == attempt else { return }
                    applyProgress = stage
                }
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    report(.preparingWorkspace)
                    var project = item.summary.schemaVersion >= 2 && item.canInspectContents
                        ? try PatchProjectLibrary.synchronizeWorkspace(item: item)
                        : baseProject
                    if item.isBundled { project.name = item.displayName }
                    _ = try DevicePatchService.apply(project: project, progress: report)
                }.value

                // Only an editable workspace changes the package on disk.
                if item.summary.schemaVersion >= 2 && item.canInspectContents {
                    store.reload()
                }
                log("patch: apply completed in \(Int(Date().timeIntervalSince(operationStarted))) seconds")
                actionAlert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.applied_message")
            } catch let error as PatchPackageError {
                log("patch: apply failed \(error)")
                actionAlert = PatchStoreAlert(
                    titleKey: "common.failed",
                    messageKey: privateErrorKey(for: error),
                    messageArgument: privateErrorArgument(for: error)
                )
            } catch {
                log("patch: apply failed \(error.localizedDescription)")
                actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.apply")
            }
        }
    }

    private var changedRestoreMessage: String {
        guard item?.project?.isPrivate != true || item?.isAuthorCopy == true else {
            return language.text(
                "patch.restore_changed_private_message",
                Int64(restoreChangedPaths.count)
            )
        }
        var visiblePaths = restoreChangedPaths.prefix(5).joined(separator: "\n")
        if restoreChangedPaths.count > 5 {
            visiblePaths += "\n…"
        }
        return language.text(
            "patch.restore_changed_message",
            Int64(restoreChangedPaths.count),
            visiblePaths
        )
    }

    @MainActor
    private func prepareRestore() {
        guard !isWorking, !appState.kernelExploitRunning, let receipt,
              store.beginPatchOperation() else { return }
        isWorking = true
        operationStarted = Date()
        applyProgress = .restoring
        Task {
            defer {
                refreshReceipt()
                isWorking = false
                store.endPatchOperation()
            }
            do {
                let inspection = try await Task.detached(priority: .userInitiated) {
                    let inspection = try DevicePatchService.inspectRestore(receipt: receipt)
                    if inspection.changedTargets.isEmpty {
                        try DevicePatchService.restore(receipt: receipt)
                    }
                    return inspection
                }.value
                if inspection.changedTargets.isEmpty {
                    actionAlert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.restored_message")
                } else {
                    restoreChangedPaths = inspection.changedTargets.map(\.displayPath)
                    showChangedRestoreConfirmation = true
                }
            } catch let error as PatchPackageError {
                actionAlert = PatchStoreAlert(
                    titleKey: "common.failed",
                    messageKey: privateErrorKey(for: error),
                    messageArgument: privateErrorArgument(for: error)
                )
            } catch {
                actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.restore")
            }
        }
    }

    @MainActor
    private func restore(allowChangedTargets: Bool) {
        guard !isWorking, !appState.kernelExploitRunning, let receipt,
              store.beginPatchOperation() else { return }
        isWorking = true
        operationStarted = Date()
        applyProgress = .restoring
        Task {
            defer {
                refreshReceipt()
                isWorking = false
                store.endPatchOperation()
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try DevicePatchService.restore(
                        receipt: receipt,
                        allowChangedTargets: allowChangedTargets
                    )
                }.value
                actionAlert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.restored_message")
            } catch let error as PatchPackageError {
                actionAlert = PatchStoreAlert(
                    titleKey: "common.failed",
                    messageKey: privateErrorKey(for: error),
                    messageArgument: privateErrorArgument(for: error)
                )
            } catch {
                actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.restore")
            }
        }
    }

    private func privateErrorKey(for error: PatchPackageError) -> String {
        if error == .missingAppGroup || error == .accessUnavailable || error == .unsupportedDevice {
            return error.localizationKey
        }
        if case .targetAppUnavailable = error {
            return "patch.error.target_access"
        }
        if case .targetOccupied = error {
            return "patch.error.target_busy"
        }
        if error == .projectAlreadyApplied {
            return error.localizationKey
        }
        guard item?.project?.isPrivate == true,
              item?.isAuthorCopy == false else {
            return error.localizationKey
        }
        return "patch.error.private_operation"
    }

    private func privateErrorArgument(for error: PatchPackageError) -> String? {
        guard item?.project?.isPrivate == true,
              item?.isAuthorCopy == false else {
            return error.localizationArgument
        }
        return nil
    }
}

/// Restores saved transactions independently of the current package catalog.
struct AppliedPatchRecoveryView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: PatchProjectStore
    @Binding var isWorking: Bool
    var conflictingProject: PatchProject? = nil
    @State private var transactions: [ActivePatchTransaction] = []
    @State private var selected: ActivePatchTransaction?
    @State private var changedCount = 0
    @State private var showConfirmation = false
    @State private var alert: PatchStoreAlert?

    var body: some View {
        List {
            Section {
                Text(language.text("patch.recovery.description"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if transactions.isEmpty {
                Section {
                    Label(language.text("patch.recovery.empty"), systemImage: "checkmark.circle")
                }
            } else {
                ForEach(transactions) { transaction in
                    Section {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(title(for: transaction)).font(.headline)
                            Text(transaction.bundleIDs.joined(separator: "\n"))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(transaction.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(String(transaction.receipt.projectID.uuidString.prefix(8)))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            if transaction.needsRecovery {
                                Label(language.text("patch.recovery.pending"), systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Button {
                            inspect(transaction)
                        } label: {
                            Label(language.text("patch.restore"), systemImage: "arrow.uturn.backward.circle")
                        }
                        .disabled(isWorking || store.isBusy || store.isPatchOperationRunning || appState.kernelExploitRunning)
                    }
                }
            }
            if isWorking { ProgressView(language.text("patch.progress.restore")) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(language.text("patch.recovery.title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isWorking)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(isWorking)
                    .accessibilityLabel(language.text("backup.refresh"))
            }
        }
        .onAppear(perform: reload)
        .interactiveDismissDisabled(isWorking)
        .confirmationDialog(
            language.text(changedCount > 0 ? "patch.restore_changed_title" : "patch.restore_confirm_title"),
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            if let selected {
                Button(language.text(changedCount > 0 ? "patch.restore_changed_action" : "patch.restore"), role: .destructive) {
                    restore(selected, allowChangedTargets: changedCount > 0)
                }
            }
            Button(language.text("common.cancel"), role: .cancel) { selected = nil }
        } message: {
            if changedCount > 0 {
                Text(language.text("patch.restore_changed_private_message", Int64(changedCount)))
            } else {
                Text(language.text("patch.recovery.confirm"))
            }
        }
        .alert(item: $alert) { value in
            Alert(title: Text(language.text(value.titleKey)),
                  message: Text(value.message(language: language)),
                  dismissButton: .default(Text(language.text("common.ok"))))
        }
    }

    private func title(for transaction: ActivePatchTransaction) -> String {
        let item = store.items.first(where: { $0.id == transaction.receipt.projectID })
        if let item, item.isBundled { return item.displayName }
        if let name = transaction.projectName, !name.isEmpty { return name }
        if let item { return item.displayName }
        return language.text("patch.recovery.previous")
    }

    private func reload() {
        transactions = DevicePatchService.activeTransactions(conflictingWith: conflictingProject)
    }

    @MainActor
    private func inspect(_ transaction: ActivePatchTransaction) {
        guard !isWorking, !appState.kernelExploitRunning, store.beginPatchOperation() else { return }
        isWorking = true
        let receipt = transaction.receipt
        Task {
            defer { isWorking = false; store.endPatchOperation() }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try DevicePatchService.inspectRestore(receipt: receipt)
                }.value
                selected = transaction
                changedCount = result.changedTargets.count
                showConfirmation = true
            } catch { report(error) }
        }
    }

    @MainActor
    private func restore(_ transaction: ActivePatchTransaction, allowChangedTargets: Bool) {
        guard !isWorking, !appState.kernelExploitRunning, store.beginPatchOperation() else { return }
        isWorking = true
        let receipt = transaction.receipt
        Task {
            defer { isWorking = false; store.endPatchOperation() }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try DevicePatchService.restore(receipt: receipt, allowChangedTargets: allowChangedTargets)
                }.value
                selected = nil
                reload()
                alert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.recovery.restored")
            } catch { report(error) }
        }
    }

    @MainActor
    private func report(_ error: Error) {
        if let packageError = error as? PatchPackageError {
            if case .restoreTargetsChanged = packageError {
                alert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.recovery.changed_again")
            } else {
                alert = PatchStoreAlert(titleKey: "common.failed", messageKey: packageError.localizationKey,
                                        messageArgument: packageError.localizationArgument)
            }
        } else {
            alert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.restore")
        }
    }
}
