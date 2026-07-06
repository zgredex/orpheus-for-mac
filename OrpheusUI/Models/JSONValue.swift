import Foundation

enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }
}

struct SettingsDocument: Equatable {
    private(set) var root: [String: JSONValue]

    init(root: [String: JSONValue]) {
        self.root = root
    }

    subscript(path path: [String]) -> JSONValue? {
        get { value(at: path) }
        set { setValue(newValue ?? .null, at: path) }
    }

    var qobuzAppID: String {
        get { string(at: ["modules", "qobuz", "app_id"]) }
        set { setString(newValue, at: ["modules", "qobuz", "app_id"]) }
    }

    var qobuzAppSecret: String {
        get { string(at: ["modules", "qobuz", "app_secret"]) }
        set { setString(newValue, at: ["modules", "qobuz", "app_secret"]) }
    }

    var qobuzAuthToken: String {
        get { string(at: ["modules", "qobuz", "auth_token"]) }
        set { setString(newValue, at: ["modules", "qobuz", "auth_token"]) }
    }

    var qobuzUserID: String {
        get { string(at: ["modules", "qobuz", "user_id"]) }
        set { setString(newValue, at: ["modules", "qobuz", "user_id"]) }
    }

    var downloadPath: String {
        get { string(at: ["global", "general", "download_path"]) }
        set { setString(newValue, at: ["global", "general", "download_path"]) }
    }

    var downloadQuality: String {
        get { string(at: ["global", "general", "download_quality"]) }
        set { setString(newValue, at: ["global", "general", "download_quality"]) }
    }

    var codecConversionsEnabled: Bool {
        guard case .object(let conversions)? = value(at: ["global", "advanced", "codec_conversions"]) else {
            return false
        }
        return !conversions.isEmpty
    }

    mutating func stripLocalCredentials(defaultDownloadPath: String, disableConversions: Bool) {
        qobuzAuthToken = ""
        qobuzUserID = ""
        if downloadPath.isEmpty || downloadPath.hasPrefix("./") || downloadPath.hasPrefix("../") {
            downloadPath = defaultDownloadPath
        }
        if downloadQuality.isEmpty {
            downloadQuality = "hifi"
        }
        if disableConversions {
            setValue(.object([:]), at: ["global", "advanced", "codec_conversions"])
        }
    }

    private func string(at path: [String]) -> String {
        value(at: path)?.stringValue ?? ""
    }

    private mutating func setString(_ string: String, at path: [String]) {
        setValue(.string(string), at: path)
    }

    private func value(at path: [String]) -> JSONValue? {
        guard !path.isEmpty else { return .object(root) }
        var current: JSONValue = .object(root)
        for key in path {
            guard case .object(let object) = current, let next = object[key] else {
                return nil
            }
            current = next
        }
        return current
    }

    private mutating func setValue(_ value: JSONValue, at path: [String]) {
        guard let first = path.first else { return }
        setValue(value, keys: Array(path.dropFirst()), in: &root, firstKey: first)
    }

    private func setValue(_ value: JSONValue, keys: [String], in object: inout [String: JSONValue], firstKey: String) {
        if keys.isEmpty {
            object[firstKey] = value
            return
        }

        let nextKey = keys[0]
        var child = object[firstKey]?.objectValue ?? [:]
        setValue(value, keys: Array(keys.dropFirst()), in: &child, firstKey: nextKey)
        object[firstKey] = .object(child)
    }
}

enum SettingsStore {
    static func load(from url: URL) throws -> SettingsDocument {
        let data = try Data(contentsOf: url)
        let root = try JSONDecoder().decode([String: JSONValue].self, from: data)
        return SettingsDocument(root: root)
    }

    static func save(_ document: SettingsDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(document.root)
        try data.write(to: url, options: .atomic)
    }
}
