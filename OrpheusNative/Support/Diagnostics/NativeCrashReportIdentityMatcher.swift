import Foundation

struct NativeCrashReportIdentityMatcher: Sendable {
    private let bundleIdentifier: String
    private let processNames: Set<String>

    init(bundleIdentifier: String, processNames: [String]) {
        self.bundleIdentifier = Self.normalized(bundleIdentifier)
        self.processNames = Set(processNames.map(Self.normalized).filter { !$0.isEmpty })
    }

    func matches(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        return matchesStructuredJSON(data, text: text) || matchesCrashHeader(text)
    }

    private func matchesStructuredJSON(_ data: Data, text: String) -> Bool {
        if let dictionary = Self.jsonDictionary(from: data), matches(dictionary) {
            return true
        }
        for line in text.split(whereSeparator: \Character.isNewline).prefix(8) {
            guard let dictionary = Self.jsonDictionary(from: Data(line.utf8)) else { continue }
            if matches(dictionary) { return true }
        }
        return false
    }

    private func matches(_ dictionary: [String: Any]) -> Bool {
        for (key, value) in dictionary {
            guard let value = value as? String else { continue }
            switch key.lowercased() {
            case "bundleid", "bundleidentifier", "bundle_id":
                if !bundleIdentifier.isEmpty, Self.normalized(value) == bundleIdentifier { return true }
            case "app_name", "appname", "procname", "processname", "process_name":
                if processNames.contains(Self.normalized(value)) { return true }
            default:
                continue
            }
        }
        return false
    }

    private func matchesCrashHeader(_ text: String) -> Bool {
        for line in text.split(whereSeparator: \Character.isNewline).prefix(160) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawValue = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "identifier", "bundle identifier":
                if !bundleIdentifier.isEmpty, Self.normalized(rawValue) == bundleIdentifier { return true }
            case "process":
                if processNames.contains(Self.normalized(Self.removingProcessIdentifier(rawValue))) {
                    return true
                }
            default:
                continue
            }
        }
        return false
    }

    private static func jsonDictionary(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func removingProcessIdentifier(_ value: String) -> String {
        guard value.last == "]",
              let openingBracket = value.lastIndex(of: "[")
        else { return value }
        let identifier = value[value.index(after: openingBracket)..<value.index(before: value.endIndex)]
        guard !identifier.isEmpty, identifier.allSatisfy(\.isNumber) else { return value }
        return String(value[..<openingBracket]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
