import SwiftUI

/// The backup tab: automatic per-write snapshots, manual backups, full
/// workspace archives and one-tap restore, with a unified activity timeline
/// (WQManager History parity). Snapshot-level flows live in
/// BackupCenterView; save archives in AppSaveBackupView.
struct BackupTabView: View {
    @Environment(\.appLanguage) private var language
    private let backupCenter = BackupCenter.shared
    @State private var records: [BackupRecord] = []
    @State private var fullBackups: [FullBackupService.ArchivedBackup] = []
    @State private var saveBackups: [AppSaveBackupService.BackupEntry] = []
    @State private var activity: [ActivityEvent] = []
    @State private var storageUsage: Int64 = 0
    @State private var isBusy = false
    @State private var activeAlert: BackupTabAlert?
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            List {
                autoBackupSection
                snapshotSection
                fullBackupSection
                saveArchiveSection
                activitySection
            }
            .navigationTitle(language.text("backup.tab.title"))
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { reload() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            createFullBackup()
                        } label: {
                            Label(language.text("fullbackup.create"), systemImage: "externaldrive.badge.plus")
                        }
                        .disabled(isBusy)
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .accessibilityLabel(language.text("fullbackup.create"))
                }
            }
            .alert(item: $activeAlert, content: alertContent)
            .onAppear {
                guard !hasLoaded else { return }
                hasLoaded = true
                reload()
            }
        }
    }

    // MARK: - Sections

    private var autoBackupSection: some View {
        Section {
            Label(language.text("backup.tab.auto_note"), systemImage: "checkmark.seal")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Label(language.text("backup.tab.auto_header"), systemImage: "arrow.triangle.2.circlepath")
        } footer: {
            Text(language.text("backup.tab.auto_footer"))
        }
    }

    private var snapshotSection: some View {
        Section {
            LabeledContent(language.text("backup.tab.snapshot_count")) {
                Text("\(records.count)").monospacedDigit()
            }
            LabeledContent(language.text("backup.tab.storage_usage")) {
                Text(ByteCountFormatter.string(fromByteCount: storageUsage, countStyle: .file))
                    .monospacedDigit()
            }
            NavigationLink {
                BackupCenterView()
            } label: {
                Label(language.text("backup.tab.manage_snapshots"), systemImage: "list.bullet")
            }
        } header: {
            Label(language.text("backup.tab.snapshots_header"), systemImage: "archivebox")
        }
    }

    private var fullBackupSection: some View {
        Section {
            if fullBackups.isEmpty {
                Text(language.text("fullbackup.empty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(fullBackups) { backup in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backup.createdAt, style: .date)
                            .font(.subheadline.weight(.medium))
                        Text(ByteCountFormatter.string(fromByteCount: backup.sizeBytes, countStyle: .file))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        restoreFull(backup)
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isBusy)
                    .accessibilityLabel(language.text("backup.restore"))
                }
                .contextMenu {
                    Button(role: .destructive) {
                        FullBackupService.delete(backup)
                        reload()
                    } label: {
                        Label(language.text("common.delete"), systemImage: "trash")
                    }
                }
            }
            Button {
                createFullBackup()
            } label: {
                Label(language.text("fullbackup.create"), systemImage: "externaldrive.badge.plus")
            }
            .disabled(isBusy)
        } header: {
            Label(language.text("fullbackup.header"), systemImage: "externaldrive.badge.timemachine")
        } footer: {
            Text(language.text("fullbackup.footer"))
        }
    }

    private var saveArchiveSection: some View {
        Section {
            if saveBackups.isEmpty {
                Text(language.text("savebackup.empty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(saveBackups.prefix(5)) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.manifest.appName.isEmpty
                         ? entry.manifest.bundleID : entry.manifest.appName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(entry.manifest.bundleID) · \(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if saveBackups.count > 5 {
                Text(language.text("backup.tab.more_archives", saveBackups.count - 5))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            NavigationLink {
                AppSaveBackupView()
            } label: {
                Label(language.text("savebackup.title"), systemImage: "arrow.down.doc")
            }
        } header: {
            Label(language.text("savebackup.archives_header"), systemImage: "arrow.down.doc.fill")
        }
    }

    private var activitySection: some View {
        Section {
            if activity.isEmpty {
                Text(language.text("backup.tab.activity_empty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(activity.prefix(20)) { event in
                HStack(spacing: 10) {
                    Image(systemName: icon(for: event.kind))
                        .foregroundStyle(tint(for: event.kind))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(language.text("activity.kind.\(event.kind.rawValue)"))
                            .font(.subheadline.weight(.medium))
                        Text(event.detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(event.date, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label(language.text("backup.tab.activity_header"), systemImage: "clock.arrow.circlepath")
        }
    }

    // MARK: - Helpers

    private func icon(for kind: ActivityEvent.Kind) -> String {
        switch kind {
        case .backup: return "arrow.down.doc"
        case .restore: return "arrow.uturn.backward.circle"
        case .clean: return "sparkles"
        case .write: return "pencil.and.outline"
        }
    }

    private func tint(for kind: ActivityEvent.Kind) -> Color {
        switch kind {
        case .backup: return .blue
        case .restore: return AppTheme.accent
        case .clean: return .green
        case .write: return .orange
        }
    }

    // MARK: - Actions

    private func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let loadedRecords = backupCenter.records()
            let loadedUsage = backupCenter.storageUsage()
            let loadedFull = FullBackupService.listBackups()
            let loadedSaves = AppSaveBackupService.listBackups()
            let loadedActivity = ActivityHistory.load()
            DispatchQueue.main.async {
                records = loadedRecords
                storageUsage = loadedUsage
                fullBackups = loadedFull
                saveBackups = loadedSaves
                activity = loadedActivity
            }
        }
    }

    private func createFullBackup() {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try FullBackupService.createFullBackup()
                ActivityHistory.log(
                    .backup,
                    feature: "fullbackup",
                    url.lastPathComponent
                )
                DispatchQueue.main.async {
                    isBusy = false
                    reload()
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

    private func restoreFull(_ backup: FullBackupService.ArchivedBackup) {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FullBackupService.restore(backup)
                ActivityHistory.log(
                    .restore,
                    feature: "fullbackup",
                    backup.fileURL.lastPathComponent
                )
                DispatchQueue.main.async {
                    isBusy = false
                    activeAlert = .message(language.text("fullbackup.restore_done"))
                    reload()
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

    private func alertContent(for alert: BackupTabAlert) -> Alert {
        Alert(
            title: Text(language.text("backup.tab.title")),
            message: Text(alert.message),
            dismissButton: .default(Text(language.text("common.ok")))
        )
    }
}

enum BackupTabAlert: Identifiable {
    case message(String)

    var message: String {
        if case .message(let text) = self { return text }
        return ""
    }

    var id: String { "backuptab-\(message)" }
}
