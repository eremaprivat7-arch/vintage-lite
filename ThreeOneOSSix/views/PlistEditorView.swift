import SwiftUI
import CoreFoundation

enum PlistStep: Hashable {
    case key(String)
    case index(Int)
}

struct PlistEntry: Identifiable {
    let id: String
    let step: PlistStep
    let name: String
    let typeName: String
    let preview: String
    let isContainer: Bool
}

final class PlistDocument {
    let root: NSMutableDictionary
    let format: PropertyListSerialization.PropertyListFormat

    init(data: Data) throws {
        var format = PropertyListSerialization.PropertyListFormat.binary
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        )
        guard let dictionary = Self.deepMutable(plist) as? NSMutableDictionary else {
            throw PlistEditorError.rootNotDictionary
        }
        self.root = dictionary
        self.format = format
    }

    func container(at path: [PlistStep]) -> Any? {
        var current: Any = root
        for step in path {
            switch step {
            case .key(let key):
                guard let dictionary = current as? NSMutableDictionary,
                      let next = dictionary.object(forKey: key) else { return nil }
                current = next
            case .index(let index):
                guard let array = current as? NSMutableArray,
                      index >= 0, index < array.count else { return nil }
                current = array.object(at: index)
            }
        }
        return current
    }

    func entries(at path: [PlistStep]) -> [PlistEntry] {
        guard let container = container(at: path) else { return [] }
        if let dictionary = container as? NSMutableDictionary {
            let keys = dictionary.allKeys.compactMap { $0 as? String }.sorted()
            return keys.map { key in
                let value = dictionary.object(forKey: key) as Any
                return PlistEntry(
                    id: "key:\(key)",
                    step: .key(key),
                    name: key,
                    typeName: typeName(value),
                    preview: preview(value),
                    isContainer: isContainer(value)
                )
            }
        }
        if let array = container as? NSMutableArray {
            return (0..<array.count).map { index in
                let value = array.object(at: index) as Any
                return PlistEntry(
                    id: "index:\(index)",
                    step: .index(index),
                    name: "[\(index)]",
                    typeName: typeName(value),
                    preview: preview(value),
                    isContainer: isContainer(value)
                )
            }
        }
        return []
    }

    func value(at path: [PlistStep], step: PlistStep) -> Any? {
        guard let container = container(at: path) else { return nil }
        switch step {
        case .key(let key):
            return (container as? NSMutableDictionary)?.object(forKey: key)
        case .index(let index):
            guard let array = container as? NSMutableArray,
                  index >= 0, index < array.count else { return nil }
            return array.object(at: index)
        }
    }

    func set(_ value: Any, at path: [PlistStep], step: PlistStep) throws {
        guard let container = container(at: path) else { throw PlistEditorError.invalidPath }
        switch step {
        case .key(let key):
            guard let dictionary = container as? NSMutableDictionary else {
                throw PlistEditorError.invalidPath
            }
            dictionary.setObject(value, forKey: key as NSString)
        case .index(let index):
            guard let array = container as? NSMutableArray,
                  index >= 0, index < array.count else { throw PlistEditorError.invalidPath }
            array.replaceObject(at: index, with: value)
        }
    }

    func remove(at path: [PlistStep], step: PlistStep) throws {
        guard let container = container(at: path) else { throw PlistEditorError.invalidPath }
        switch step {
        case .key(let key):
            guard let dictionary = container as? NSMutableDictionary else {
                throw PlistEditorError.invalidPath
            }
            dictionary.removeObject(forKey: key)
        case .index(let index):
            guard let array = container as? NSMutableArray,
                  index >= 0, index < array.count else { throw PlistEditorError.invalidPath }
            array.removeObject(at: index)
        }
    }

    func add(value: Any, key: String?, at path: [PlistStep]) throws {
        guard let container = container(at: path) else { throw PlistEditorError.invalidPath }
        if let dictionary = container as? NSMutableDictionary {
            guard let key, !key.isEmpty else { throw PlistEditorError.invalidKey }
            dictionary.setObject(value, forKey: key as NSString)
        } else if let array = container as? NSMutableArray {
            array.add(value)
        } else {
            throw PlistEditorError.invalidPath
        }
    }

    func serialized() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: root,
            format: format,
            options: 0
        )
    }

    func typeName(_ value: Any) -> String {
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "Boolean" : "Number"
        }
        if value is String { return "String" }
        if value is Data { return "Data" }
        if value is Date { return "Date" }
        if value is NSDictionary || value is [String: Any] { return "Dictionary" }
        if value is NSArray || value is [Any] { return "Array" }
        return "Value"
    }

    func isContainer(_ value: Any) -> Bool {
        value is NSDictionary || value is NSArray || value is [String: Any] || value is [Any]
    }

    func preview(_ value: Any) -> String {
        if let dictionary = value as? NSDictionary {
            return "\(dictionary.count) keys"
        }
        if let array = value as? NSArray {
            return "\(array.count) items"
        }
        if let data = value as? Data {
            return "\(data.count) bytes"
        }
        if let date = value as? Date {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let string = value as? String {
            return string.count > 60 ? String(string.prefix(60)) + "…" : string
        }
        return ""
    }

    private static func deepMutable(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            let mutable = NSMutableDictionary()
            for (key, child) in dictionary {
                mutable.setObject(deepMutable(child), forKey: key as NSString)
            }
            return mutable
        }
        if let array = value as? [Any] {
            let mutable = NSMutableArray()
            for child in array {
                mutable.add(deepMutable(child))
            }
            return mutable
        }
        return value
    }
}

enum PlistEditorError: Error, LocalizedError {
    case rootNotDictionary
    case invalidPath
    case invalidKey
    case invalidValue

    var errorDescription: String? {
        switch self {
        case .rootNotDictionary: return "The root plist is not a dictionary."
        case .invalidPath: return "The plist path is no longer valid."
        case .invalidKey: return "A non-empty key is required."
        case .invalidValue: return "The value could not be converted."
        }
    }
}

struct PlistEditorView: View {
    @Environment(\.appLanguage) private var language
    let path: String

    @State private var document: PlistDocument?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var showSaveConfirmation = false
    @State private var notice: PlistNotice?

    private struct PlistNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView(language.text("plist.loading"))
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding()
            } else if let document {
                PlistContainerView(
                    document: document,
                    path: [],
                    onSave: { showSaveConfirmation = true }
                )
            }
        }
        .navigationTitle(language.text("plist.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .confirmationDialog(
            language.text("plist.save_confirm_title"),
            isPresented: $showSaveConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("plist.save"), role: .destructive) {
                save()
            }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("plist.save_confirm_message"))
        }
        .alert(item: $notice) { value in
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

    private func load() {
        isLoading = true
        errorMessage = nil
        let path = path
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let loaded = try PlistDocument(data: data)
                DispatchQueue.main.async {
                    document = loaded
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

    private func save() {
        guard let document else { return }
        isWorking = true
        let path = path
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try document.serialized()
                guard !data.isEmpty else { throw PlistEditorError.invalidValue }
                try VerifiedFileWriter.write(
                    data,
                    to: URL(fileURLWithPath: path),
                    feature: .file,
                    reason: "plist edit"
                )
                DispatchQueue.main.async {
                    isWorking = false
                    notice = PlistNotice(
                        title: language.text("plist.saved_title"),
                        message: language.text("plist.saved_message")
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    isWorking = false
                    notice = PlistNotice(
                        title: language.text("plist.error_title"),
                        message: error.localizedDescription
                    )
                }
            }
        }
    }
}

struct PlistContainerView: View {
    @Environment(\.appLanguage) private var language
    let document: PlistDocument
    let path: [PlistStep]
    let onSave: () -> Void

    @State private var revision = 0
    @State private var editing: PlistEditRequest?
    @State private var showAdd = false
    @State private var newKey = ""
    @State private var errorMessage: String?

    private struct PlistEditRequest: Identifiable {
        let id = UUID()
        let step: PlistStep
        let name: String
        let value: Any
    }

    private var entries: [PlistEntry] {
        _ = revision
        return document.entries(at: path)
    }

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    if entry.isContainer {
                        NavigationLink {
                            PlistContainerView(
                                document: document,
                                path: path + [entry.step],
                                onSave: onSave
                            )
                        } label: {
                            row(entry)
                        }
                    } else {
                        Button {
                            editing = PlistEditRequest(
                                step: entry.step,
                                name: entry.name,
                                value: document.value(at: path, step: entry.step) as Any
                            )
                        } label: {
                            row(entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onDelete(perform: delete)
            } header: {
                Text(path.isEmpty ? language.text("plist.root") : language.text("plist.container"))
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(path.isEmpty ? language.text("plist.title") : language.text("plist.container"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    newKey = ""
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            if path.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        onSave()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
        }
        .sheet(item: $editing) { request in
            PlistValueEditor(
                document: document,
                path: path,
                step: request.step,
                name: request.name,
                initialValue: request.value
            ) {
                revision += 1
            }
        }
        .alert(language.text("plist.add_key"), isPresented: $showAdd) {
            TextField(language.text("plist.key_name"), text: $newKey)
            Button(language.text("plist.add"), role: .destructive) {
                addEntry()
            }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("plist.add_key_message"))
        }
    }

    private func row(_ entry: PlistEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                Text(entry.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(entry.typeName)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func delete(at offsets: IndexSet) {
        do {
            for index in offsets {
                try document.remove(at: path, step: entries[index].step)
            }
            revision += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addEntry() {
        do {
            let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let container = document.container(at: path)
            if container is NSMutableDictionary {
                guard !key.isEmpty else { throw PlistEditorError.invalidKey }
                try document.add(value: "", key: key, at: path)
            } else {
                try document.add(value: "", key: nil, at: path)
            }
            revision += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PlistValueEditor: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss

    let document: PlistDocument
    let path: [PlistStep]
    let step: PlistStep
    let name: String
    let initialValue: Any
    let onChanged: () -> Void

    @State private var type: PlistValueType = .string
    @State private var text = ""
    @State private var boolean = false
    @State private var errorMessage: String?

    private enum PlistValueType: String, CaseIterable, Identifiable {
        case string, number, real, boolean, data, date
        var id: String { rawValue }
        var title: String {
            switch self {
            case .string: return "String"
            case .number: return "Integer"
            case .real: return "Real"
            case .boolean: return "Boolean"
            case .data: return "Data"
            case .date: return "Date"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(language.text("plist.value")) {
                    Picker(language.text("plist.type"), selection: $type) {
                        ForEach(PlistValueType.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    if type == .boolean {
                        Toggle(language.text("plist.value"), isOn: $boolean)
                    } else {
                        TextField(language.text("plist.value"), text: $text)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("common.ok")) { save() }
                }
            }
        }
        .onAppear(perform: configure)
    }

    private func configure() {
        if let number = initialValue as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                type = .boolean
                boolean = number.boolValue
            } else if CFNumberIsFloatType(unsafeBitCast(number, to: CFNumber.self)) {
                // Preserve Real values (e.g. camera zoom factors): writing
                // them back as Integers black-screens the camera viewfinder.
                type = .real
                text = number.stringValue
            } else {
                type = .number
                text = number.stringValue
            }
        } else if let string = initialValue as? String {
            type = .string
            text = string
        } else if let data = initialValue as? Data {
            type = .data
            text = data.base64EncodedString()
        } else if let date = initialValue as? Date {
            type = .date
            text = ISO8601DateFormatter().string(from: date)
        }
    }

    private func save() {
        do {
            let value: Any
            switch type {
            case .string:
                value = text
            case .number:
                guard let number = Int(text) else { throw PlistEditorError.invalidValue }
                value = number
            case .real:
                // Round-trip through Double so <real> stays <real>.
                guard let number = Double(text), number.isFinite else {
                    throw PlistEditorError.invalidValue
                }
                value = NSNumber(value: number)
            case .boolean:
                value = boolean
            case .data:
                guard let data = Data(base64Encoded: text) else {
                    throw PlistEditorError.invalidValue
                }
                value = data
            case .date:
                guard let date = ISO8601DateFormatter().date(from: text) else {
                    throw PlistEditorError.invalidValue
                }
                value = date
            }
            try document.set(value, at: path, step: step)
            onChanged()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}