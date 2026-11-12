import SwiftUI
import Darwin

// MARK: - SQLite bridge

private enum SQLiteConstants {
    static let ok: Int32 = 0
    static let row: Int32 = 100
    static let done: Int32 = 101
    static let openReadOnly: Int32 = 0x0000_0001
}

private final class SQLiteAPI {
    typealias OpenFn = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?) -> Int32
    typealias CloseFn = @convention(c) (OpaquePointer?) -> Int32
    typealias PrepareFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    typealias StepFn = @convention(c) (OpaquePointer?) -> Int32
    typealias FinalizeFn = @convention(c) (OpaquePointer?) -> Int32
    typealias ColumnCountFn = @convention(c) (OpaquePointer?) -> Int32
    typealias ColumnNameFn = @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<CChar>?
    typealias ColumnTypeFn = @convention(c) (OpaquePointer?, Int32) -> Int32
    typealias ColumnInt64Fn = @convention(c) (OpaquePointer?, Int32) -> Int64
    typealias ColumnDoubleFn = @convention(c) (OpaquePointer?, Int32) -> Double
    typealias ColumnTextFn = @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<UInt8>?
    typealias ColumnBytesFn = @convention(c) (OpaquePointer?, Int32) -> Int32
    typealias ErrMsgFn = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?

    let open: OpenFn
    let close: CloseFn
    let prepare: PrepareFn
    let step: StepFn
    let finalize: FinalizeFn
    let columnCount: ColumnCountFn
    let columnName: ColumnNameFn
    let columnType: ColumnTypeFn
    let columnInt64: ColumnInt64Fn
    let columnDouble: ColumnDoubleFn
    let columnText: ColumnTextFn
    let columnBytes: ColumnBytesFn
    let errmsg: ErrMsgFn

    init?() {
        guard let library = dlopen("/usr/lib/libsqlite3.dylib", RTLD_NOW) else {
            return nil
        }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(library, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let open = symbol("sqlite3_open_v2", as: OpenFn.self),
              let close = symbol("sqlite3_close", as: CloseFn.self),
              let prepare = symbol("sqlite3_prepare_v2", as: PrepareFn.self),
              let step = symbol("sqlite3_step", as: StepFn.self),
              let finalize = symbol("sqlite3_finalize", as: FinalizeFn.self),
              let columnCount = symbol("sqlite3_column_count", as: ColumnCountFn.self),
              let columnName = symbol("sqlite3_column_name", as: ColumnNameFn.self),
              let columnType = symbol("sqlite3_column_type", as: ColumnTypeFn.self),
              let columnInt64 = symbol("sqlite3_column_int64", as: ColumnInt64Fn.self),
              let columnDouble = symbol("sqlite3_column_double", as: ColumnDoubleFn.self),
              let columnText = symbol("sqlite3_column_text", as: ColumnTextFn.self),
              let columnBytes = symbol("sqlite3_column_bytes", as: ColumnBytesFn.self),
              let errmsg = symbol("sqlite3_errmsg", as: ErrMsgFn.self) else {
            return nil
        }
        self.open = open
        self.close = close
        self.prepare = prepare
        self.step = step
        self.finalize = finalize
        self.columnCount = columnCount
        self.columnName = columnName
        self.columnType = columnType
        self.columnInt64 = columnInt64
        self.columnDouble = columnDouble
        self.columnText = columnText
        self.columnBytes = columnBytes
        self.errmsg = errmsg
    }
}

struct SQLiteTable: Identifiable, Equatable {
    let name: String
    let type: String

    var id: String { name }
}

struct SQLiteRows {
    let columns: [String]
    let rows: [[String]]
}

enum SQLiteReaderError: Error, LocalizedError {
    case unavailable
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "SQLite is unavailable."
        case .openFailed(let detail): return "Could not open the database: \(detail)"
        case .queryFailed(let detail): return "Query failed: \(detail)"
        }
    }
}

final class SQLiteReader {
    private let api: SQLiteAPI
    private let database: OpaquePointer
    private let temporaryDirectory: URL

    init(sourceURL: URL) throws {
        guard let api = SQLiteAPI() else { throw SQLiteReaderError.unavailable }
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory
            .appendingPathComponent("3106-sqlite-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        let copy = temporary.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            try manager.copyItem(at: sourceURL, to: copy)
            for suffix in ["-wal", "-shm"] {
                let sideSource = URL(fileURLWithPath: sourceURL.path + suffix)
                if manager.fileExists(atPath: sideSource.path) {
                    try manager.copyItem(
                        at: sideSource,
                        to: URL(fileURLWithPath: copy.path + suffix)
                    )
                }
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw SQLiteReaderError.openFailed(error.localizedDescription)
        }

        var handle: OpaquePointer?
        let result = copy.path.withCString { path in
            api.open(path, &handle, SQLiteConstants.openReadOnly, nil)
        }
        guard result == SQLiteConstants.ok, let handle else {
            try? manager.removeItem(at: temporary)
            throw SQLiteReaderError.openFailed("sqlite3_open_v2 returned \(result)")
        }
        self.api = api
        self.database = handle
        self.temporaryDirectory = temporary
    }

    deinit {
        _ = api.close(database)
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func tables() throws -> [SQLiteTable] {
        let result = try query(
            "SELECT name, type FROM sqlite_master " +
                "WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        return result.rows.compactMap { row in
            guard row.count >= 2 else { return nil }
            return SQLiteTable(name: row[0], type: row[1])
        }
    }

    func rowCount(for table: String) throws -> Int64 {
        let result = try query("SELECT COUNT(*) FROM \(quoted(table))")
        return Int64(result.rows.first?.first ?? "0") ?? 0
    }

    func rows(for table: String, limit: Int = 500, offset: Int = 0) throws -> SQLiteRows {
        try query("SELECT * FROM \(quoted(table)) LIMIT \(limit) OFFSET \(offset)")
    }

    func csv(for table: String, limit: Int = 10_000) throws -> String {
        let result = try rows(for: table, limit: limit)
        var lines = [result.columns.map(csvEscape).joined(separator: ",")]
        for row in result.rows {
            lines.append(row.map(csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    func query(_ sql: String) throws -> SQLiteRows {
        var statement: OpaquePointer?
        let prepareResult = sql.withCString { pointer in
            api.prepare(database, pointer, -1, &statement, nil)
        }
        guard prepareResult == SQLiteConstants.ok, let statement else {
            let message = api.errmsg(database).map { String(cString: $0) } ?? "unknown error"
            throw SQLiteReaderError.queryFailed(message)
        }
        defer { _ = api.finalize(statement) }

        let count = Int(api.columnCount(statement))
        var columns: [String] = []
        columns.reserveCapacity(count)
        for index in 0..<count {
            columns.append(api.columnName(statement, Int32(index)).map { String(cString: $0) } ?? "column\(index)")
        }

        var rows: [[String]] = []
        while api.step(statement) == SQLiteConstants.row {
            var row: [String] = []
            row.reserveCapacity(count)
            for index in 0..<count {
                row.append(value(statement: statement, index: Int32(index)))
            }
            rows.append(row)
            if rows.count >= 2_000 { break }
        }
        return SQLiteRows(columns: columns, rows: rows)
    }

    private func value(statement: OpaquePointer, index: Int32) -> String {
        switch api.columnType(statement, index) {
        case 1:
            return String(api.columnInt64(statement, index))
        case 2:
            return String(api.columnDouble(statement, index))
        case 3:
            guard let pointer = api.columnText(statement, index) else { return "" }
            let length = Int(api.columnBytes(statement, index))
            let buffer = UnsafeBufferPointer(start: pointer, count: max(0, length))
            return String(decoding: buffer, as: UTF8.self)
        case 4:
            return "<\(api.columnBytes(statement, index)) bytes>"
        default:
            return "NULL"
        }
    }

    private func quoted(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

// MARK: - UI

struct SQLiteViewerView: View {
    @Environment(\.appLanguage) private var language
    @State private var reader: SQLiteReader?
    @State private var tables: [SQLiteTable] = []
    @State private var errorMessage: String?
    @State private var isLoading = true
    let path: String

    var body: some View {
        Group {
            if isLoading {
                ProgressView(language.text("sqlite.loading"))
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else if let reader {
                List {
                    Section(language.text("sqlite.tables")) {
                        ForEach(tables) { table in
                            NavigationLink {
                                SQLiteTableDetailView(reader: reader, table: table)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(table.name)
                                        Text(table.type)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: table.type == "view" ? "eye" : "tablecells")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Section {
                        NavigationLink {
                            SQLiteQueryView(reader: reader)
                        } label: {
                            Label(language.text("sqlite.query"), systemImage: "terminal")
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(language.text("sqlite.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        isLoading = true
        errorMessage = nil
        let path = path
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let opened = try SQLiteReader(sourceURL: URL(fileURLWithPath: path))
                let list = try opened.tables()
                DispatchQueue.main.async {
                    reader = opened
                    tables = list
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

struct SQLiteTableDetailView: View {
    @Environment(\.appLanguage) private var language
    let reader: SQLiteReader
    let table: SQLiteTable

    @State private var rows = SQLiteRows(columns: [], rows: [])
    @State private var rowCount: Int64 = 0
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding()
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        header
                        ForEach(Array(rows.rows.enumerated()), id: \.offset) { index, row in
                            HStack(spacing: 0) {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                                    Text(value)
                                        .font(.caption2.monospaced())
                                        .lineLimit(1)
                                        .frame(minWidth: 90, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                }
                            }
                            .background(index.isMultiple(of: 2)
                                ? Color(uiColor: .secondarySystemBackground).opacity(0.4)
                                : Color.clear)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .overlay(alignment: .bottom) {
                    Text(language.text("sqlite.rows_footer", rowCount, Int64(rows.rows.count)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.regularMaterial)
                }
            }
        }
        .navigationTitle(table.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(rows.columns, id: \.self) { column in
                Text(column)
                    .font(.caption2.monospaced().weight(.semibold))
                    .lineLimit(1)
                    .frame(minWidth: 90, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
        }
        .background(Color(uiColor: .tertiarySystemBackground))
    }

    private func load() {
        isLoading = true
        let reader = reader
        let table = table
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let count = try reader.rowCount(for: table.name)
                let data = try reader.rows(for: table.name)
                DispatchQueue.main.async {
                    rowCount = count
                    rows = data
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

struct SQLiteQueryView: View {
    @Environment(\.appLanguage) private var language
    let reader: SQLiteReader

    @State private var query = "SELECT name FROM sqlite_master LIMIT 20"
    @State private var result = SQLiteRows(columns: [], rows: [])
    @State private var errorMessage: String?
    @State private var isRunning = false

    var body: some View {
        VStack(spacing: 12) {
            TextEditor(text: $query)
                .font(.caption.monospaced())
                .frame(minHeight: 120)
                .padding(8)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

            Button {
                run()
            } label: {
                Label(language.text("sqlite.run"), systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRunning)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !result.columns.isEmpty {
                        HStack(spacing: 0) {
                            ForEach(result.columns, id: \.self) { column in
                                Text(column)
                                    .font(.caption2.monospaced().weight(.semibold))
                                    .frame(minWidth: 90, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                            }
                        }
                        .background(Color(uiColor: .tertiarySystemBackground))
                    }
                    ForEach(Array(result.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                                Text(value)
                                    .font(.caption2.monospaced())
                                    .frame(minWidth: 90, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .navigationTitle(language.text("sqlite.query"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run() {
        isRunning = true
        errorMessage = nil
        let reader = reader
        let sql = query
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try reader.query(sql)
                DispatchQueue.main.async {
                    result = data
                    isRunning = false
                }
            } catch {
                DispatchQueue.main.async {
                    isRunning = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}