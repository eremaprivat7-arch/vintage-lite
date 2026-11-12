import SwiftUI
import UniformTypeIdentifiers

struct FileInfoView: View {
    @Environment(\.appLanguage) private var language
    let path: String

    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var values: [InfoRow] = []

    private struct InfoRow: Identifiable {
        let id = UUID()
        let title: String
        let value: String
    }

    var body: some View {
        List {
            if isLoading {
                HStack {
                    ProgressView()
                    Text(language.text("fileinfo.loading"))
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Section(language.text("fileinfo.section.general")) {
                    ForEach(values) { row in
                        LabeledContent(row.title) {
                            Text(row.value)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(language.text("fileinfo.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        isLoading = true
        errorMessage = nil
        let path = path
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = URL(fileURLWithPath: path)
                let resourceValues = try url.resourceValues(forKeys: [
                    .fileSizeKey,
                    .creationDateKey,
                    .contentModificationDateKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .isRegularFileKey,
                    .contentTypeKey,
                ])
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                let size = resourceValues.fileSize ?? (attributes[.size] as? NSNumber)?.intValue ?? 0
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                let type = resourceValues.contentType?.localizedDescription
                    ?? (resourceValues.isDirectory == true
                        ? language.text("fileinfo.type.folder")
                        : language.text("fileinfo.type.file"))

                var rows: [InfoRow] = [
                    InfoRow(title: language.text("fileinfo.name"), value: url.lastPathComponent),
                    InfoRow(title: language.text("fileinfo.path"), value: path),
                    InfoRow(title: language.text("fileinfo.type"), value: type),
                    InfoRow(
                        title: language.text("fileinfo.size"),
                        value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                    ),
                ]
                if let modified = resourceValues.contentModificationDate {
                    rows.append(InfoRow(
                        title: language.text("fileinfo.modified"),
                        value: modified.formatted(date: .abbreviated, time: .standard)
                    ))
                }
                if let created = resourceValues.creationDate {
                    rows.append(InfoRow(
                        title: language.text("fileinfo.created"),
                        value: created.formatted(date: .abbreviated, time: .standard)
                    ))
                }
                rows.append(InfoRow(
                    title: language.text("fileinfo.permissions"),
                    value: String(format: "%03o", permissions & 0o777)
                ))
                if let owner = attributes[.ownerAccountName] as? String {
                    rows.append(InfoRow(title: language.text("fileinfo.owner"), value: owner))
                }
                if let group = attributes[.groupOwnerAccountName] as? String {
                    rows.append(InfoRow(title: language.text("fileinfo.group"), value: group))
                }
                if resourceValues.isSymbolicLink == true {
                    rows.append(InfoRow(
                        title: language.text("fileinfo.symlink"),
                        value: language.text("common.yes")
                    ))
                }

                DispatchQueue.main.async {
                    values = rows
                    isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}