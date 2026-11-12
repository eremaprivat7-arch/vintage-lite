import SwiftUI
import UniformTypeIdentifiers

/// Arbitrary file replacement (operator-specified flow, Erosion-CN
/// OperationsView parity extended):
/// 1. pick an app (list) and a file inside its container (browser)
/// 2. pick the replacement file from the Files picker
/// 3. optional "back up the original first" checkbox, then replace
/// 4. a persistent replace log with one-tap restore — survives relaunch.
/// A manual path entry (Erosion's original flow) is kept under Advanced.
struct FileReplaceView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss

    // Target state
    @State private var apps: [InstalledApp] = []
    @State private var selectedApp: InstalledApp?
    @State private var targetPath: String = ""
    @State private var targetInfo: TargetInfo?
    @State private var isResolvingTarget = false

    // Replacement state
    @State private var showImporter = false
    @State private var replacementData: Data?
    @State private var replacementName = ""
    @State private var backupRequested = true
    @State private var isBusy = false

    // Log state
    @State private var records: [FileReplaceService.ReplaceRecord] = []
    // Preset state (saved app+path recipes)
    @State private var presets: [FileReplaceService.ReplacePreset] = []
    @State private var showSavePresetSheet = false

    @State private var activeAlert: ReplaceAlert?
    @State private var shareURL: URL?
    @State private var manualPathSheet = false
    @State private var hasLoaded = false

    private static let anyType = UTType.data

    struct TargetInfo: Equatable {
        let exists: Bool
        let sizeBytes: Int64
        let isProtected: Bool
    }

    var body: some View {
        List {
            targetSection
            presetsSection
            replacementSection
            replaceActionSection
            recordsSection
        }
        .navigationTitle(language.text("filereplace.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { reload() }
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            reload()
        }
        .sheet(isPresented: $showImporter) {
            FileDocumentPicker(
                allowedContentTypes: [Self.anyType],
                copiesSelectedDocument: true,
                allowsMultipleSelection: false,
                onSelection: { result in
                    showImporter = false
                    if case .success(let urls) = result, let url = urls.first {
                        importReplacement(from: url)
                    }
                },
                onCancel: { showImporter = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showSavePresetSheet) {
            SavePresetSheet(
                defaultName: (selectedApp?.displayName ?? "") + " · "
                    + ((targetPath as NSString).lastPathComponent)
            ) { name in
                FileReplaceService.savePreset(
                    name: name,
                    bundleID: selectedApp?.bundleID ?? "",
                    appName: selectedApp?.displayName ?? language.text("filereplace.manual_target"),
                    targetPath: targetPath,
                    backupRequested: backupRequested
                )
                presets = FileReplaceService.loadPresets()
                showSavePresetSheet = false
            }
        }
        .sheet(isPresented: $manualPathSheet) {
            ManualPathSheet { path, bundleID, appName in
                selectTarget(path: path, bundleID: bundleID, appName: appName)
                manualPathSheet = false
            }
        }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let url = shareURL {
                ActivityShareSheet(items: [url])
            }
        }
        .alert(item: $activeAlert, content: alertContent)
    }

    // MARK: - Sections

    private var targetSection: some View {
        Section {
            // No red banner here: replacements inside APP containers work on
            // BOTH backends (bad_query on iOS 26.0-26.6.1 and worse_query on
            // 26.7+/27) — the exploit is picked by version automatically.
            // System-group targets are refused by the service rails with a
            // localized reason, so a standing banner would be noise.

            if let selectedApp {
                LabeledContent(language.text("filereplace.target_app")) {
                    Text(selectedApp.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if targetPath.isEmpty {
                NavigationLink {
                    FileReplaceAppPicker { app, path in
                        selectTarget(
                            path: path,
                            bundleID: app.bundleID,
                            appName: app.displayName
                        )
                    }
                } label: {
                    Label(language.text("filereplace.pick_app"), systemImage: "iphone.gen3")
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(targetPath)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let targetInfo {
                        HStack(spacing: 8) {
                            Text(targetInfo.exists
                                 ? ByteCountFormatter.string(fromByteCount: targetInfo.sizeBytes, countStyle: .file)
                                 : language.text("filereplace.not_exists"))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if targetInfo.isProtected {
                                Label(language.text("filereplace.protected"), systemImage: "hand.raised.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }

                HStack {
                    Button(role: .destructive) {
                        clearTarget()
                    } label: {
                        Label(language.text("filereplace.change_target"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    if let targetInfo, targetInfo.exists {
                        Button {
                            exportTarget()
                        } label: {
                            Label(language.text("filereplace.export"), systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(isBusy)
                    }
                }
            }

            Button {
                manualPathSheet = true
            } label: {
                Label(language.text("filereplace.manual_path"), systemImage: "keyboard")
            }
            .disabled(isBusy)
        } header: {
            Label(language.text("filereplace.target_header"), systemImage: "scope")
        } footer: {
            Text(language.text("filereplace.target_footer"))
        }
    }

    private var presetsSection: some View {
        Section {
            if presets.isEmpty {
                Text(language.text("filereplace.presets_empty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(presets) { preset in
                Button {
                    applyPreset(preset)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: "bookmark.fill")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.accent)
                            Text(preset.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                        Text(preset.targetPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        FileReplaceService.deletePreset(id: preset.id)
                        presets = FileReplaceService.loadPresets()
                    } label: {
                        Label(language.text("common.delete"), systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        FileReplaceService.deletePreset(id: preset.id)
                        presets = FileReplaceService.loadPresets()
                    } label: {
                        Label(language.text("common.delete"), systemImage: "trash")
                    }
                }
            }

            if targetInfo != nil {
                Button {
                    showSavePresetSheet = true
                } label: {
                    Label(language.text("filereplace.save_preset"), systemImage: "bookmark")
                }
                .disabled(isBusy)
            }
        } header: {
            Label(language.text("filereplace.presets_header"), systemImage: "bookmark.circle")
        } footer: {
            Text(language.text("filereplace.presets_footer"))
        }
    }

    private func applyPreset(_ preset: FileReplaceService.ReplacePreset) {
        // One tap re-anchors the whole target flow from a saved recipe.
        if let app = apps.first(where: { $0.bundleID == preset.bundleID }) {
            selectedApp = app
        }
        targetPath = preset.targetPath
        backupRequested = preset.backupRequested
        refreshTargetInfo(path: preset.targetPath)
    }

    private var replacementSection: some View {
        Section {
            if let replacementData {
                LabeledContent(language.text("filereplace.replacement")) {
                    Text("\(replacementName) · \(ByteCountFormatter.string(fromByteCount: Int64(replacementData.count), countStyle: .file))")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button(role: .destructive) {
                    self.replacementData = nil
                    self.replacementName = ""
                } label: {
                    Label(language.text("filereplace.clear_replacement"), systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
            } else {
                Button {
                    showImporter = true
                } label: {
                    Label(language.text("filereplace.pick_replacement"), systemImage: "square.and.arrow.down")
                }
            }
        } header: {
            Label(language.text("filereplace.replacement_header"), systemImage: "arrowshape.replace.forward")
        } footer: {
            Text(language.text("filereplace.replacement_footer"))
        }
    }

    @ViewBuilder
    private var replaceActionSection: some View {
        Section {
            Toggle(isOn: $backupRequested) {
                Label(language.text("filereplace.backup_toggle"), systemImage: "externaldrive.badge.timemachine")
            }
            .disabled(targetPath.isEmpty || replacementData == nil)

            Button {
                performReplace()
            } label: {
                Label(language.text("filereplace.replace_button"), systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: 20)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canReplace)

            Button(role: .destructive) {
                performDelete()
            } label: {
                Label(language.text("filereplace.delete_button"), systemImage: "trash")
            }
            .disabled(targetPath.isEmpty || targetInfo?.exists != true || isBusy)
        } header: {
            Label(language.text("filereplace.action_header"), systemImage: "gearshape.2")
        } footer: {
            Text(language.text("filereplace.action_footer"))
        }
    }

    private var recordsSection: some View {
        Section {
            if records.isEmpty {
                Text(language.text("filereplace.no_records"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: record.operation == .delete
                              ? "trash" : record.operation == .writeNew ? "plus.square" : "arrowshape.replace.forward")
                            .font(.caption2)
                            .foregroundStyle(record.operation == .delete ? .red : AppTheme.accent)
                        Text("\(record.appName) · \(language.text("filereplace.op.\(record.operation.rawValue)"))")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                    }
                    Text(record.targetPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack {
                        Text(record.date, style: .date)
                        Text("·")
                        if record.backupPath != nil {
                            Text(language.text("filereplace.has_backup"))
                        } else {
                            Text(language.text("filereplace.no_backup"))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .swipeActions {
                    if record.backupPath != nil {
                        Button {
                            performRestore(record)
                        } label: {
                            Label(language.text("filereplace.restore"), systemImage: "arrow.uturn.backward.circle")
                        }
                        .tint(AppTheme.accent)
                        .disabled(isBusy)
                    }
                    Button(role: .destructive) {
                        removeRecord(record)
                    } label: {
                        Label(language.text("common.delete"), systemImage: "trash")
                    }
                }
                .contextMenu {
                    if record.backupPath != nil {
                        Button {
                            performRestore(record)
                        } label: {
                            Label(language.text("filereplace.restore"), systemImage: "arrow.uturn.backward.circle")
                        }
                    }
                    Button {
                        removeRecord(record)
                    } label: {
                        Label(language.text("common.delete"), systemImage: "trash")
                    }
                }
            }
        } header: {
            Label(language.text("filereplace.records_header"), systemImage: "clock.arrow.circlepath")
        } footer: {
            Text(language.text("filereplace.records_footer"))
        }
    }

    private var canReplace: Bool {
        !targetPath.isEmpty
            && replacementData != nil
            && (targetInfo?.isProtected != true)
            && !isBusy
    }

    // MARK: - Actions

    private func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let loadedApps = AppSaveBackupService.eligibleApps()
            let loadedRecords = FileReplaceService.loadLog()
            let loadedPresets = FileReplaceService.loadPresets()
            DispatchQueue.main.async {
                apps = loadedApps
                records = loadedRecords
                presets = loadedPresets
                if let path = targetPath.isEmpty ? nil : targetPath {
                    refreshTargetInfo(path: path)
                }
            }
        }
    }

    private func selectTarget(path: String, bundleID: String, appName: String) {
        targetPath = path
        // Re-anchor the app row for display; the path is the stable handle.
        if let app = apps.first(where: { $0.bundleID == bundleID }) {
            selectedApp = app
        }
        refreshTargetInfo(path: path)
    }

    private func refreshTargetInfo(path: String) {
        if let reason = FileReplaceService.blockedSystemPathReason(for: path) {
            targetInfo = TargetInfo(exists: false, sizeBytes: 0, isProtected: true)
            _ = reason
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let grant = ContainerStore.grantContainerAccess(
                (path as NSString).deletingLastPathComponent
            )
            defer {
                if grant >= 0 { SandboxAccess.release(grant) }
            }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
            var size: Int64 = 0
            if exists {
                size = (try? URL(fileURLWithPath: path).resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize).flatMap { Int64($0) } ?? 0
            }
            DispatchQueue.main.async {
                if path == targetPath {
                    targetInfo = TargetInfo(
                        exists: exists,
                        sizeBytes: size,
                        isProtected: false
                    )
                }
            }
        }
    }

    private func clearTarget() {
        targetPath = ""
        targetInfo = nil
        selectedApp = nil
    }

    private func importReplacement(from url: URL) {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            let data = (try? Data(contentsOf: url)) ?? Data()
            DispatchQueue.main.async {
                replacementData = data
                replacementName = url.lastPathComponent
                isBusy = false
            }
        }
    }

    private func performReplace() {
        guard let payload = replacementData, !targetPath.isEmpty else { return }
        let bundleID = selectedApp?.bundleID ?? ""
        let appName = selectedApp?.displayName ?? language.text("filereplace.manual_target")
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try FileReplaceService.replace(
                    targetPath: targetPath,
                    payload: payload,
                    bundleID: bundleID,
                    appName: appName,
                    backupRequested: backupRequested
                )
                DispatchQueue.main.async {
                    isBusy = false
                    records = FileReplaceService.loadLog()
                    refreshTargetInfo(path: targetPath)
                    activeAlert = .message(language.text("filereplace.replace_done"))
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

    private func performDelete() {
        guard !targetPath.isEmpty else { return }
        let bundleID = selectedApp?.bundleID ?? ""
        let appName = selectedApp?.displayName ?? language.text("filereplace.manual_target")
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try FileReplaceService.deleteTarget(
                    targetPath: targetPath,
                    bundleID: bundleID,
                    appName: appName
                )
                DispatchQueue.main.async {
                    isBusy = false
                    records = FileReplaceService.loadLog()
                    refreshTargetInfo(path: targetPath)
                    activeAlert = .message(language.text("filereplace.delete_done"))
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

    private func performRestore(_ record: FileReplaceService.ReplaceRecord) {
        guard !isBusy else { return }
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileReplaceService.restore(record: record)
                FileReplaceService.pruneRestoreAsides(
                    inContainerPath: record.targetPath
                )
                DispatchQueue.main.async {
                    isBusy = false
                    records = FileReplaceService.loadLog()
                    refreshTargetInfo(path: record.targetPath)
                    activeAlert = .message(language.text("filereplace.restore_done"))
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

    private func removeRecord(_ record: FileReplaceService.ReplaceRecord) {
        // Removing the log entry also drops the backup file, so the backup
        // directory cannot grow without bound behind stale entries.
        if let backupPath = record.backupPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: backupPath))
        }
        FileReplaceService.clearLogEntry(id: record.id)
        records = FileReplaceService.loadLog()
    }

    private func exportTarget() {
        guard !targetPath.isEmpty else { return }
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try FileReplaceService.exportTarget(targetPath: targetPath)
                DispatchQueue.main.async {
                    isBusy = false
                    shareURL = url
                }
            } catch {
                DispatchQueue.main.async {
                    isBusy = false
                    activeAlert = .message(language.errorText(error))
                }
            }
        }
    }

    private func alertContent(for alert: ReplaceAlert) -> Alert {
        Alert(
            title: Text(language.text("filereplace.title")),
            message: Text(alert.message),
            dismissButton: .default(Text(language.text("common.ok")))
        )
    }
}

// MARK: - Supporting pieces

enum ReplaceAlert: Identifiable {
    case message(String)

    var message: String {
        if case .message(let text) = self { return text }
        return ""
    }

    var id: String { "filereplace-\(message)" }
}

/// Share-sheet wrapper reused from the replace/export flows.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Manual path entry (Erosion's original flow): advanced users type an
/// absolute path instead of navigating containers.
private struct ManualPathSheet: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @State private var pathText = ""
    @State private var bundleText = ""
    @State private var nameText = ""

    let onPick: (String, String, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(language.text("filereplace.manual_path")) {
                    TextField("/var/mobile/Containers/Data/Application/…/Documents/file", text: $pathText)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField(language.text("filereplace.manual_bundle"), text: $bundleText)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField(language.text("filereplace.manual_name"), text: $nameText)
                }
            }
            .navigationTitle(language.text("filereplace.manual_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("common.confirm")) {
                        onPick(
                            pathText.trimmingCharacters(in: .whitespacesAndNewlines),
                            bundleText.trimmingCharacters(in: .whitespacesAndNewlines),
                            nameText.isEmpty
                                ? language.text("filereplace.manual_target")
                                : nameText
                        )
                    }
                    .disabled(pathText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// App + in-container file picker (operator flow step 1-2, refined):
/// pick an app, then NAVIGATE its container directory by directory and tap
/// a file. Enumeration is per-level (contentsOfDirectory, not a recursive
/// walk) so every level is instant on both the bad_query (iOS 26) and
/// worse_query (iOS 26.7+/27) backends — the same grant entry serves both.
struct FileReplaceAppPicker: View {
    @Environment(\.appLanguage) private var language
    @State private var apps: [InstalledApp] = []
    @State private var hasLoaded = false

    let onPick: (InstalledApp, String) -> Void

    var body: some View {
        List {
            if apps.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(language.text("filereplace.loading_apps"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(apps) { app in
                NavigationLink {
                    FileReplaceDirectoryBrowser(
                        containerPath: app.containerPath,
                        rootTitle: app.displayName
                    ) { path in
                        onPick(app, path)
                    }
                } label: {
                    HStack(spacing: 10) {
                        AppCardRowIcon(image: app.icon)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.displayName)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(app.bundleID)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .navigationTitle(language.text("filereplace.pick_app"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            DispatchQueue.global(qos: .userInitiated).async {
                let loaded = AppSaveBackupService.eligibleApps()
                DispatchQueue.main.async {
                    apps = loaded
                }
            }
        }
    }
}

/// One level of the container: subdirectories (navigable) and files
/// (selectable), directories first. Backed by contentsOfDirectory under a
/// sandbox grant — works identically on both backends.
struct FileReplaceDirectoryBrowser: View {
    @Environment(\.appLanguage) private var language

    let containerPath: String
    let rootTitle: String
    let onPick: (String) -> Void

    @State private var currentPath: String
    @State private var entries: [Entry] = []
    @State private var isLoading = true
    @State private var navigationStack: [String] = []

    struct Entry: Identifiable, Equatable {
        let path: String
        let name: String
        let isDirectory: Bool
        let sizeBytes: Int64

        var id: String { path }
    }

    init(
        containerPath: String,
        rootTitle: String,
        onPick: @escaping (String) -> Void
    ) {
        self.containerPath = containerPath
        self.rootTitle = rootTitle
        self.onPick = onPick
        _currentPath = State(initialValue: containerPath)
    }

    var body: some View {
        List {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(language.text("filereplace.loading_files"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // Up-navigation row (not shown at the container root).
            if !navigationStack.isEmpty {
                Button {
                    navigateUp()
                } label: {
                    Label("..", systemImage: "arrow.uturn.up")
                        .font(.system(.subheadline, design: .monospaced))
                }
            }
            ForEach(entries) { entry in
                if entry.isDirectory {
                    Button {
                        navigateDown(entry)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(AppTheme.accent)
                                .frame(width: 22)
                            Text(entry.name)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        onPick(entry.path)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc")
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            Text(entry.name)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(ByteCountFormatter.string(
                                fromByteCount: entry.sizeBytes, countStyle: .file
                            ))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(currentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadCurrentLevel() }
    }

    private var currentTitle: String {
        navigationStack.last ?? rootTitle
    }

    private func navigateDown(_ entry: Entry) {
        navigationStack.append(entry.name)
        currentPath = entry.path
        loadCurrentLevel()
    }

    private func navigateUp() {
        navigationStack.removeLast()
        currentPath = navigationStack.isEmpty
            ? containerPath
            : (currentPath as NSString).deletingLastPathComponent
        loadCurrentLevel()
    }

    private func loadCurrentLevel() {
        isLoading = true
        let level = currentPath
        DispatchQueue.global(qos: .userInitiated).async {
            let grant = ContainerStore.grantContainerAccess(level)
            defer {
                if grant >= 0 { SandboxAccess.release(grant) }
            }
            let fm = FileManager.default
            let names = (try? fm.contentsOfDirectory(atPath: level)) ?? []
            var loaded: [Entry] = []
            for name in names where !name.hasPrefix(".") {
                let full = (level as NSString).appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDirectory) else {
                    continue
                }
                // Symlinks are shown but never navigable: replacing THROUGH a
                // symlinked directory would escape the container.
                if isDirectory.boolValue {
                    loaded.append(Entry(path: full, name: name, isDirectory: true, sizeBytes: 0))
                } else {
                    let size = (try? URL(fileURLWithPath: full).resourceValues(
                        forKeys: [.fileSizeKey]
                    ).fileSize).flatMap { Int64($0) } ?? 0
                    loaded.append(Entry(path: full, name: name, isDirectory: false, sizeBytes: size))
                }
                if loaded.count >= 500 { break }
            }
            let sorted = loaded.sorted { left, right in
                if left.isDirectory != right.isDirectory {
                    return left.isDirectory
                }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            DispatchQueue.main.async {
                guard level == currentPath else { return }
                entries = sorted
                isLoading = false
            }
        }
    }
}

/// Names a saved replace recipe (app + path + backup flag).
struct SavePresetSheet: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @State private var nameText: String

    let defaultName: String
    let onSave: (String) -> Void

    init(defaultName: String, onSave: @escaping (String) -> Void) {
        self.defaultName = defaultName
        self.onSave = onSave
        _nameText = State(initialValue: defaultName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(language.text("filereplace.save_preset")) {
                    TextField(language.text("filereplace.preset_name"), text: $nameText)
                        .autocorrectionDisabled()
                }
                Section {
                    Text(language.text("filereplace.presets_footer"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(language.text("filereplace.save_preset"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("common.save")) {
                        let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmed.isEmpty ? defaultName : trimmed)
                    }
                }
            }
        }
    }
}
