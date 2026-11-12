import SwiftUI

/// App save backup page (Erosion-CN parity): pick a third-party app, package
/// Documents + Library/Preferences into a .3106save archive, and restore
/// after a reinstall (container re-matched by bundle ID). Protected bundle
/// IDs are never listed.
struct AppSaveBackupView: View {
    @Environment(\.appLanguage) private var language
    @State private var apps: [InstalledApp] = []
    @State private var backups: [AppSaveBackupService.BackupEntry] = []
    @State private var isBusy = false
    @State private var busyAppName = ""
    @State private var activeAlert: SaveBackupAlert?
    @State private var hasLoaded = false

    var body: some View {
        List {
            backupsSection
            appsSection
        }
        .navigationTitle(language.text("savebackup.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { reload() }
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            reload()
        }
        .alert(item: $activeAlert, content: alertContent)
    }

    // MARK: - Sections

    private var backupsSection: some View {
        Section {
            if backups.isEmpty {
                Text(language.text("savebackup.empty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(backups) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.manifest.appName.isEmpty
                         ? entry.manifest.bundleID : entry.manifest.appName)
                        .font(.subheadline.weight(.medium))
                    Text("\(entry.manifest.bundleID) · \(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(entry.manifest.createdAt, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        AppSaveBackupService.delete(entry)
                        reload()
                    } label: {
                        Label(language.text("common.delete"), systemImage: "trash")
                    }
                    .disabled(isBusy)
                    Button {
                        restore(entry)
                    } label: {
                        Label(language.text("savebackup.restore"), systemImage: "arrow.uturn.backward.circle")
                    }
                    .tint(AppTheme.accent)
                    .disabled(isBusy)
                }
                .contextMenu {
                    Button {
                        restore(entry)
                    } label: {
                        Label(language.text("savebackup.restore"), systemImage: "arrow.uturn.backward.circle")
                    }
                    .disabled(isBusy)
                    Button {
                        share(entry.fileURL)
                    } label: {
                        Label(language.text("savebackup.share"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(isBusy)
                }
            }
        } header: {
            Label(language.text("savebackup.archives_header"), systemImage: "archivebox")
        } footer: {
            Text(language.text("savebackup.archives_footer"))
        }
    }

    private var appsSection: some View {
        Section {
            if apps.isEmpty && !isBusy {
                Text(language.text("savebackup.no_apps"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(apps) { app in
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
                    Spacer()
                    if isBusy && busyAppName == app.bundleID {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            backup(app)
                        } label: {
                            Image(systemName: "arrow.down.doc")
                        }
                        .buttonStyle(.borderless)
                        .disabled(isBusy)
                        .accessibilityLabel(language.text("savebackup.backup_action"))
                    }
                }
            }
        } header: {
            Label(language.text("savebackup.apps_header"), systemImage: "iphone.gen3")
        } footer: {
            Text(language.text("savebackup.apps_footer"))
        }
    }

    // MARK: - Actions

    private func reload() {
        isBusy = apps.isEmpty
        DispatchQueue.global(qos: .userInitiated).async {
            let loadedApps = AppSaveBackupService.eligibleApps()
            let loadedBackups = AppSaveBackupService.listBackups()
            DispatchQueue.main.async {
                apps = loadedApps
                backups = loadedBackups
                isBusy = false
            }
        }
    }

    private func backup(_ app: InstalledApp) {
        busyAppName = app.bundleID
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try AppSaveBackupService.backup(app: app)
                DispatchQueue.main.async {
                    isBusy = false
                    busyAppName = ""
                    SoundEffects.play(.success)
                    reload()
                }
            } catch {
                DispatchQueue.main.async {
                    isBusy = false
                    busyAppName = ""
                    SoundEffects.play(.failure)
                    activeAlert = .message(language.errorText(error))
                }
            }
        }
    }

    private func restore(_ entry: AppSaveBackupService.BackupEntry) {
        // Concurrent restores against the same container interleave the
        // rename-aside/rollback/copy steps — serialize at the entry point.
        guard !isBusy else { return }
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AppSaveBackupService.restore(entry)
                DispatchQueue.main.async {
                    isBusy = false
                    activeAlert = .message(language.text("savebackup.restore_done"))
                }
            } catch {
                DispatchQueue.main.async {
                    isBusy = false
                    activeAlert = .message(language.errorText(error))
                }
            }
        }
    }

    private func share(_ url: URL) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad requires a popover source or presentation crashes.
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.keyWindow?.rootViewController {
            activity.popoverPresentationController?.sourceView = root.view
            activity.popoverPresentationController?.sourceRect = CGRect(
                x: root.view.bounds.midX, y: root.view.bounds.maxY - 8,
                width: 1, height: 1
            )
            root.present(activity, animated: true)
        }
    }

    private func alertContent(for alert: SaveBackupAlert) -> Alert {
        Alert(
            title: Text(language.text("savebackup.title")),
            message: Text(alert.message),
            dismissButton: .default(Text(language.text("common.ok")))
        )
    }
}

enum SaveBackupAlert: Identifiable {
    case message(String)

    var message: String {
        if case .message(let text) = self { return text }
        return ""
    }

    var id: String { "savebackup-\(message)" }
}
