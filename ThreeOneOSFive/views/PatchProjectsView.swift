import SwiftUI
import UIKit
struct PatchProjectsView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var draftCoordinator: PatchDraftCoordinator
    @StateObject private var store = PatchProjectStore()
    @State private var showCreate = false
    @State private var searchText = ""

    @State private var category: PatchCategory = .fps

    private var categoryItems: [PatchLibraryItem] {
        store.items.filter { $0.category == category }
    }

    private var filteredItems: [PatchLibraryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return categoryItems }
        return categoryItems.filter { item in
            if item.packageURL.lastPathComponent.localizedCaseInsensitiveContains(query) {
                return true
            }
            guard let project = item.project else { return false }
            return project.name.localizedCaseInsensitiveContains(query)
                || project.allBundleIdentifiers.contains {
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

    init() {
#if targetEnvironment(simulator)
        _showCreate = State(
            initialValue: ProcessInfo.processInfo.arguments.contains("--simulate-patch-editor")
        )
#endif
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    ZStack(alignment: .bottomLeading) {
                        GeometryReader { geometry in
                            Image("VintageSky").resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped().accessibilityHidden(true)
                        }
                        LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("VINTAGE LITE").font(.caption.weight(.bold)).tracking(3)
                            Text(category.title.uppercased()).font(.largeTitle.weight(.black))
                        }.foregroundStyle(.white).padding(18)
                    }
                    .frame(height: 165)
                    .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                    .listRowBackground(Color.black)
                    Picker("Раздел", selection: $category) {
                        ForEach(PatchCategory.allCases, id: \.self) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.black)
                    AppSearchField(
                        text: $searchText,
                        prompt: language.text("patch.search"),
                        clearLabel: language.text("common.clear")
                    ).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                        .listRowBackground(Color.black)
                    if categoryItems.isEmpty && !store.isBusy {
                        emptyState
                            .listRowSeparator(.hidden)
                    } else if filteredItems.isEmpty && !store.isBusy {
                        searchEmptyState
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(filteredItems) { item in
                            itemRow(item)
                                .deleteDisabled(item.isBundled)
                                .listRowSeparator(.hidden)
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 19)
                                        .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .overlay(RoundedRectangle(cornerRadius: 19).stroke(.white.opacity(0.16)))
                                        .padding(.horizontal, 6).padding(.vertical, 4)
                                )
                        }
                        .onDelete { offsets in
                            offsets.map { filteredItems[$0] }.forEach(store.delete)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.black)
            }
            .navigationTitle("VINTAGE LITE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showCreate = true
                        } label: {
                            Label(language.text("patch.new"), systemImage: "doc.badge.plus")
                        }
                    } label: {
                        if store.isBusy {
                            ProgressView()
                        } else {
                            Image(systemName: "plus")
                        }
                    }
                    .disabled(store.isBusy)
                    .accessibilityLabel(language.text("patch.add"))
                }
            }
            .sheet(isPresented: $showCreate) {
                PatchProjectEditorView(
                    existingProject: nil,
                    passwordIsProtected: false
                ) { project, password in
                    store.create(project: project, password: password, category: category)
                }
            }
            .sheet(item: $draftCoordinator.request) { request in
                PatchProjectEditorView(
                    existingProject: nil,
                    passwordIsProtected: false,
                    initialDraft: request.draft
                ) { project, password in
                    store.create(project: project, password: password, category: category)
                    draftCoordinator.clear()
                }
            }
            .sheet(item: $store.passwordRequest, onDismiss: store.cancelUnlock) { _ in
                PatchUnlockView(store: store)
            }
            .alert(item: $store.alert) { alert in
                Alert(
                    title: Text(language.text(alert.titleKey)),
                    message: Text(alert.message(language: language)),
                    dismissButton: .default(Text(language.text("common.ok")))
                )
            }
        }
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
            Text("В разделе \(category.title) пока нет файлов")
                .font(.headline)
            Text("Добавь пакеты в папку раздела перед сборкой.")
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

private struct PatchProjectRow: View {
    let item: PatchLibraryItem
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isLocked ? "lock.fill" : item.category.icon)
                .font(.title2.weight(.bold)).foregroundStyle(.black)
                .frame(width: 48, height: 48)
                .background(LinearGradient(colors: [.white, Color(white: 0.66)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.project?.name ?? (item.isBundled ? item.packageURL.deletingPathExtension().lastPathComponent : language.text("patch.locked_project")))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(item.isLocked
                     ? language.text("patch.tap_to_unlock")
                     : language.text(
                        item.summary.schemaVersion >= 2 ? "patch.workspace_items_count" : "patch.rules_count",
                        Int64((item.project?.rules.count ?? 0) + (item.project?.directories.count ?? 0))
                     ))
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
        }
        .padding(.vertical, 10)
    }
}

private struct PatchUnlockView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PatchProjectStore
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
                    Text(language.text("patch.password_once_message"))
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

private struct PatchProjectDetailView: View {
    @EnvironmentObject private var license: LicenseSession
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: PatchProjectStore
    let projectID: UUID
    @State private var showEditor = false
    @State private var editingRule: PatchRule?
    @State private var showApplyConfirmation = false
    @State private var showRestoreConfirmation = false
    @State private var isWorking = false
    @State private var actionAlert: PatchStoreAlert?

    private var item: PatchLibraryItem? {
        store.items.first(where: { $0.id == projectID })
    }

    private var receipt: PatchTransactionReceipt? {
        DevicePatchService.latestReceipt(projectID: projectID)
    }

    private var isWorkspaceProject: Bool {
        (item?.summary.schemaVersion ?? 1) >= 2
    }

    var body: some View {
        List {
            if let item, let project = item.project {
                if isWorkspaceProject {
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
                                    title: project.name,
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
                        if !item.isBundled { Text(language.text("patch.workspace_detail_footer")) }
                    }
                } else if !item.isBundled {
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
                    Button {
                        showApplyConfirmation = true
                    } label: {
                        actionLabel("patch.apply", systemImage: "bolt.fill")
                            .font(.headline.weight(.bold)).foregroundStyle(.black)
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(isWorking)

                    if receipt != nil {
                        Button(role: .destructive) {
                            showRestoreConfirmation = true
                        } label: {
                            actionLabel("patch.restore", systemImage: "arrow.uturn.backward.circle")
                        }
                        .disabled(isWorking)
                    }

                } footer: {
                    Text(language.text("patch.apply_footer"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item?.project?.name ?? language.text("patch.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isWorking {
                    ProgressView()
                } else if !isWorkspaceProject && item?.isBundled == false {
                    Button(language.text("patch.edit")) { showEditor = true }
                        .disabled(item?.project == nil)
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
            language.text("patch.apply_confirm_title"),
            isPresented: $showApplyConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("patch.apply")) { apply() }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("patch.apply_confirm_message"))
        }
        .confirmationDialog(
            language.text("patch.restore_confirm_title"),
            isPresented: $showRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("patch.restore"), role: .destructive) { restore() }
            Button(language.text("common.cancel"), role: .cancel) {}
        }
        .alert(item: $actionAlert) { alert in
            Alert(
                title: Text(language.text(alert.titleKey)),
                message: Text(alert.message(language: language)),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
    }

    private func actionLabel(_ key: String, systemImage: String) -> some View {
        Label(language.text(key), systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private func apply() {
        guard let item, let baseProject = item.project else { return }
        isWorking = true
        let access = license
        Task.detached(priority: .userInitiated) {
            guard await access.checkForApply() else {
                await MainActor.run { isWorking = false }
                return
            }
            do {
                let project = !item.isBundled && item.summary.schemaVersion >= 2
                    ? try PatchProjectLibrary.synchronizeWorkspace(item: item)
                    : baseProject
                _ = try DevicePatchService.apply(project: project)
                await MainActor.run {
                    store.reload()
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.applied_message")
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: error.localizationKey,
                        messageArgument: error.localizationArgument
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.apply")
                }
            }
        }
    }

    private func restore() {
        guard let receipt else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                try DevicePatchService.restore(receipt: receipt)
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.restored_message")
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: error.localizationKey,
                        messageArgument: error.localizationArgument
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.restore")
                }
            }
        }
    }
}
