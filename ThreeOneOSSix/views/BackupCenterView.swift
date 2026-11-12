import SwiftUI

struct BackupCenterView: View {
    @Environment(\.appLanguage) private var language

    @State private var records: [BackupRecord] = []
    @State private var pending: [BackupJournal] = []
    @State private var confirmationAction: PendingAction?
    @State private var showConfirmation = false
    @State private var alert: BackupAlert?
    @State private var isWorking = false

    private enum PendingAction: Identifiable {
        case restore(BackupRecord)
        case delete(BackupRecord)

        var id: String {
            switch self {
            case .restore(let record): return "restore-\(record.id.uuidString)"
            case .delete(let record): return "delete-\(record.id.uuidString)"
            }
        }
    }

    private struct BackupAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private var grouped: [(BackupFeature, [BackupRecord])] {
        let order: [BackupFeature] = [.gestalt, .keypad, .patch, .file, .wallpaper, .manual]
        return order.compactMap { feature in
            let items = records.filter { $0.feature == feature }
            return items.isEmpty ? nil : (feature, items)
        }
    }

    var body: some View {
        List {
            if !pending.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            language.text("backup.pending_title"),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        Text(language.text("backup.pending_message", Int64(pending.count)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            recoverPending()
                        } label: {
                            Label(
                                language.text("backup.recover_pending"),
                                systemImage: "arrow.counterclockwise"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                HStack {
                    Label(language.text("backup.records_count", Int64(records.count)),
                          systemImage: "externaldrive.fill")
                    Spacer()
                    Text(ByteCountFormatter.string(
                        fromByteCount: BackupCenter.shared.storageUsage(),
                        countStyle: .file
                    ))
                    .foregroundStyle(.secondary)
                }
                .font(.footnote)
            }

            if grouped.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(language.text("backup.empty_title"), systemImage: "archivebox")
                            .font(.headline)
                        Text(language.text("backup.empty_message"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                ForEach(grouped, id: \.0) { feature, items in
                    Section {
                        ForEach(items) { record in
                            NavigationLink {
                                BackupDetailView(record: record)
                            } label: {
                                row(record)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    confirmationAction = .restore(record)
                                    showConfirmation = true
                                } label: {
                                    Label(language.text("backup.restore"), systemImage: "arrow.counterclockwise")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    confirmationAction = .delete(record)
                                    showConfirmation = true
                                } label: {
                                    Label(language.text("backup.delete"), systemImage: "trash")
                                }
                                .disabled(record.kind == .original)

                                Button {
                                    togglePin(record)
                                } label: {
                                    Label(
                                        language.text(record.pinned ? "backup.unpin" : "backup.pin"),
                                        systemImage: record.pinned ? "pin.slash" : "pin"
                                    )
                                }
                                .tint(.orange)
                            }
                            .contextMenu {
                                Button {
                                    confirmationAction = .restore(record)
                                    showConfirmation = true
                                } label: {
                                    Label(language.text("backup.restore"), systemImage: "arrow.counterclockwise")
                                }
                                Button {
                                    togglePin(record)
                                } label: {
                                    Label(
                                        language.text(record.pinned ? "backup.unpin" : "backup.pin"),
                                        systemImage: record.pinned ? "pin.slash" : "pin"
                                    )
                                }
                                if record.kind != .original {
                                    Button(role: .destructive) {
                                        confirmationAction = .delete(record)
                                        showConfirmation = true
                                    } label: {
                                        Label(language.text("backup.delete"), systemImage: "trash")
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(featureTitle(feature))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(language.text("backup.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isWorking)
                .accessibilityLabel(language.text("backup.refresh"))
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            confirmationTitle,
            isPresented: $showConfirmation,
            titleVisibility: .visible,
            presenting: confirmationAction
        ) { action in
            switch action {
            case .restore(let record):
                Button(language.text("backup.restore")) {
                    restore(record)
                }
            case .delete(let record):
                Button(language.text("backup.delete"), role: .destructive) {
                    delete(record)
                }
            }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: { action in
            switch action {
            case .restore(let record):
                Text(language.text("backup.restore_message", record.fileName))
            case .delete(let record):
                Text(language.text("backup.delete_message", record.fileName))
            }
        }
        .alert(item: $alert) { value in
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

    private var confirmationTitle: String {
        switch confirmationAction {
        case .restore: return language.text("backup.restore_title")
        case .delete: return language.text("backup.delete_title")
        case .none: return language.text("backup.title")
        }
    }

    private func row(_ record: BackupRecord) -> some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: iconName(record), tint: tint(record))
            VStack(alignment: .leading, spacing: 2) {
                Text(record.fileName)
                    .lineLimit(1)
                Text(subtitle(record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if record.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ record: BackupRecord) -> String {
        "\(kindTitle(record.kind)) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file))"
    }

    private func featureTitle(_ feature: BackupFeature) -> String {
        language.text("backup.feature.\(feature.rawValue)")
    }

    private func kindTitle(_ kind: BackupKind) -> String {
        language.text("backup.kind.\(kind.rawValue)")
    }

    private func iconName(_ record: BackupRecord) -> String {
        switch record.kind {
        case .original: return "archivebox.fill"
        case .version: return "clock.arrow.circlepath"
        case .manual: return "bookmark.fill"
        }
    }

    private func tint(_ record: BackupRecord) -> Color {
        switch record.kind {
        case .original: return .green
        case .version: return .orange
        case .manual: return .blue
        }
    }

    private func reload() {
        records = BackupCenter.shared.records()
        pending = BackupCenter.shared.pendingJournals()
    }

    private func togglePin(_ record: BackupRecord) {
        do {
            try BackupCenter.shared.setPinned(!record.pinned, recordID: record.id)
            reload()
        } catch {
            alert = BackupAlert(
                title: language.text("backup.error_title"),
                message: error.localizedDescription
            )
        }
    }

    private func restore(_ record: BackupRecord) {
        run({
            try BackupCenter.shared.restore(record)
            return language.text("backup.restored_message", record.fileName)
        }, successTitle: language.text("backup.restored_title"))
    }

    private func delete(_ record: BackupRecord) {
        run({
            try BackupCenter.shared.delete(record)
            return language.text("backup.deleted_message", record.fileName)
        }, successTitle: language.text("backup.deleted_title"))
    }

    private func recoverPending() {
        run({
            let count = BackupCenter.shared.recoverPendingJournals()
            return language.text("backup.recovered", Int64(count))
        }, successTitle: language.text("backup.recovered_title"))
    }

    private func run(_ work: @escaping () throws -> String, successTitle: String) {
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let message = try work()
                DispatchQueue.main.async {
                    isWorking = false
                    reload()
                    alert = BackupAlert(title: successTitle, message: message)
                }
            } catch {
                DispatchQueue.main.async {
                    isWorking = false
                    alert = BackupAlert(
                        title: language.text("backup.error_title"),
                        message: error.localizedDescription
                    )
                }
            }
        }
    }
}

struct BackupDetailView: View {
    @Environment(\.appLanguage) private var language
    let record: BackupRecord

    var body: some View {
        List {
            Section {
                LabeledContent(language.text("backup.detail.feature"),
                              value: language.text("backup.feature.\(record.feature.rawValue)"))
                LabeledContent(language.text("backup.detail.kind"),
                              value: language.text("backup.kind.\(record.kind.rawValue)"))
                LabeledContent(language.text("backup.detail.created"),
                              value: record.createdAt.formatted(date: .abbreviated, time: .standard))
                LabeledContent(language.text("backup.detail.size"),
                              value: ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file))
            }
            Section {
                ShareLink(item: record.payloadURL(rootURL: BackupCenter.shared.rootURL)) {
                    Label(language.text("backup.export"), systemImage: "square.and.arrow.up")
                }
            }
            Section(language.text("backup.detail.path")) {
                Text(record.targetPath)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                if let containerPath = record.containerPath {
                    Text(containerPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Section(language.text("backup.detail.hash")) {
                Text(record.sha256)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                Text(record.payloadRelativePath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Section(language.text("backup.detail.reason")) {
                Text(record.reason)
                    .font(.footnote)
                Text("\(record.appVersion) · \(record.osBuild)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(language.text("backup.detail.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}