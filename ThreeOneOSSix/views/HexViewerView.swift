import SwiftUI

struct HexViewerView: View {
    @Environment(\.appLanguage) private var language

    let path: String
    let readOnly: Bool

    @State private var data = Data()
    @State private var page = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var notice: HexNotice?
    @State private var goToOffset = ""
    @State private var searchText = ""
    @State private var searchAsHex = true
    @State private var editOffset = ""
    @State private var editBytes = ""
    @State private var isWorking = false

    private let pageSize = 4_096
    private let maximumEditBytes = 64 * 1_024 * 1_024

    private struct HexNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private struct HexLine: Identifiable {
        let id: Int
        let offset: Int
        let hex: String
        let ascii: String
    }

    private var pageCount: Int {
        max(1, (data.count + pageSize - 1) / pageSize)
    }

    private var lines: [HexLine] {
        let start = page * pageSize
        guard start < data.count else { return [] }
        let end = min(data.count, start + pageSize)
        var result: [HexLine] = []
        var offset = start
        while offset < end {
            let lineEnd = min(end, offset + 16)
            let slice = data[offset..<lineEnd]
            let hex = slice.map { String(format: "%02X", $0) }
                .enumerated()
                .map { index, value in index == 7 ? value + " " : value }
                .joined(separator: " ")
            let ascii = slice.map { byte -> String in
                (32...126).contains(byte) ? String(UnicodeScalar(byte)) : "."
            }.joined()
            result.append(HexLine(id: offset, offset: offset, hex: hex, ascii: ascii))
            offset = lineEnd
        }
        return result
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView(language.text("hex.loading"))
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding()
            } else {
                VStack(spacing: 0) {
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(lines) { line in
                                HStack(spacing: 10) {
                                    Text(String(format: "%08X", line.offset))
                                        .foregroundStyle(.secondary)
                                    Text(line.hex)
                                    Text(line.ascii)
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption2.monospaced())
                                .padding(.vertical, 1)
                            }
                        }
                        .padding(10)
                    }

                    Divider()

                    VStack(spacing: 8) {
                        HStack {
                            Button(language.text("hex.prev")) {
                                page = max(0, page - 1)
                            }
                            .disabled(page == 0)
                            Text(language.text("hex.page", Int64(page + 1), Int64(pageCount)))
                                .font(.caption.monospacedDigit())
                                .frame(maxWidth: .infinity)
                            Button(language.text("hex.next")) {
                                page = min(pageCount - 1, page + 1)
                            }
                            .disabled(page >= pageCount - 1)
                        }

                        HStack {
                            TextField(language.text("hex.offset"), text: $goToOffset)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.asciiCapable)
                            Button(language.text("hex.go")) {
                                goToOffsetAction()
                            }
                        }

                        HStack {
                            TextField(language.text("hex.find"), text: $searchText)
                                .textFieldStyle(.roundedBorder)
                            Toggle(language.text("hex.find_hex"), isOn: $searchAsHex)
                                .labelsHidden()
                            Button(language.text("hex.search")) {
                                searchAction()
                            }
                        }

                        if !readOnly {
                            HStack {
                                TextField(language.text("hex.edit_offset"), text: $editOffset)
                                    .textFieldStyle(.roundedBorder)
                                TextField(language.text("hex.edit_bytes"), text: $editBytes)
                                    .textFieldStyle(.roundedBorder)
                                Button(language.text("hex.apply")) {
                                    applyEdit()
                                }
                                .disabled(isWorking)
                            }
                        }
                    }
                    .font(.caption)
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemBackground))
                }
            }
        }
        .navigationTitle(language.text("hex.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .alert(item: $notice) { value in
            Alert(
                title: Text(value.title),
                message: Text(value.message),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
    }

    private func load() {
        isLoading = true
        errorMessage = nil
        let path = path
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let loaded = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
                DispatchQueue.main.async {
                    data = loaded
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

    private func goToOffsetAction() {
        guard let offset = parseNumber(goToOffset), offset >= 0 else {
            notice = HexNotice(
                title: language.text("hex.error"),
                message: language.text("hex.invalid_offset")
            )
            return
        }
        page = min(pageCount - 1, offset / pageSize)
    }

    private func searchAction() {
        guard !searchText.isEmpty else { return }
        let needle: Data
        if searchAsHex {
            guard let bytes = parseHex(searchText) else {
                notice = HexNotice(
                    title: language.text("hex.error"),
                    message: language.text("hex.invalid_hex")
                )
                return
            }
            needle = bytes
        } else {
            needle = Data(searchText.utf8)
        }
        guard let range = data.range(of: needle) else {
            notice = HexNotice(
                title: language.text("hex.search"),
                message: language.text("hex.not_found")
            )
            return
        }
        page = range.lowerBound / pageSize
        notice = HexNotice(
            title: language.text("hex.search"),
            message: language.text("hex.found_at", Int64(range.lowerBound))
        )
    }

    private func applyEdit() {
        if data.count > maximumEditBytes {
            notice = HexNotice(
                title: language.text("hex.error"),
                message: language.text("hex.size_limit")
            )
            return
        }
        guard let offset = parseNumber(editOffset),
              offset >= 0,
              let bytes = parseHex(editBytes),
              !bytes.isEmpty else {
            notice = HexNotice(
                title: language.text("hex.error"),
                message: language.text("hex.invalid_hex")
            )
            return
        }
        guard offset + bytes.count <= data.count else {
            notice = HexNotice(
                title: language.text("hex.error"),
                message: language.text("hex.out_of_range")
            )
            return
        }

        var updated = data
        updated.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        guard updated.count == data.count else { return }
        isWorking = true
        let path = path
        let reason = "hex edit at \(offset)"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try VerifiedFileWriter.write(
                    updated,
                    to: URL(fileURLWithPath: path),
                    feature: .file,
                    reason: reason
                )
                DispatchQueue.main.async {
                    data = updated
                    isWorking = false
                    notice = HexNotice(
                        title: language.text("hex.saved"),
                        message: language.text("hex.saved_message")
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    isWorking = false
                    notice = HexNotice(
                        title: language.text("hex.error"),
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func parseNumber(_ raw: String) -> Int? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.lowercased().hasPrefix("0x") {
            return Int(value.dropFirst(2), radix: 16)
        }
        return Int(value) ?? Int(value, radix: 16)
    }

    private func parseHex(_ raw: String) -> Data? {
        let cleaned = raw
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}