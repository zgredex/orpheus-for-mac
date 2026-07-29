import Foundation

public struct LibraryRelativePath: Hashable, Codable, Sendable, CustomStringConvertible {
    public static let root = LibraryRelativePath(components: [])

    public let rawValue: String

    public init(_ rawValue: String) throws {
        if rawValue == "." {
            self.rawValue = rawValue
            return
        }
        guard QobuzPathSafety.isSafeRelativePath(rawValue) else {
            throw LibraryFileSystemError.unsafePath(rawValue)
        }
        self.rawValue = rawValue
    }

    init(components: [String]) {
        rawValue = components.isEmpty ? "." : components.joined(separator: "/")
    }

    public var description: String { rawValue }
    public var isRoot: Bool { rawValue == "." }
    public var components: [String] {
        isRoot ? [] : rawValue.split(separator: "/").map(String.init)
    }
    public var lastComponent: String? { components.last }
    public var parent: LibraryRelativePath {
        LibraryRelativePath(components: Array(components.dropLast()))
    }
    public var ancestorDirectories: [LibraryRelativePath] {
        guard components.count > 1 else { return [] }
        return (1..<components.count).map {
            LibraryRelativePath(components: Array(components.prefix($0)))
        }
    }

    public func appending(_ leafName: String) throws -> LibraryRelativePath {
        guard QobuzPathSafety.isSafeLeafName(leafName) else {
            throw LibraryFileSystemError.unsafePath(leafName)
        }
        return LibraryRelativePath(components: components + [leafName])
    }
}

public enum LibraryFileKind: String, Codable, Equatable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case other
}

public struct LibraryFileMetadata: Equatable, Sendable {
    public let kind: LibraryFileKind
    public let byteCount: Int64
    public let modificationDate: Date

    public init(kind: LibraryFileKind, byteCount: Int64, modificationDate: Date) {
        self.kind = kind
        self.byteCount = byteCount
        self.modificationDate = modificationDate
    }
}

public struct LibraryDirectoryEntry: Equatable, Sendable {
    public let path: LibraryRelativePath
    public let metadata: LibraryFileMetadata

    public init(path: LibraryRelativePath, metadata: LibraryFileMetadata) {
        self.path = path
        self.metadata = metadata
    }
}

public struct LibraryTraversalIssue: Equatable, Sendable {
    public let path: LibraryRelativePath
    public let message: String

    public init(path: LibraryRelativePath, message: String) {
        self.path = path
        self.message = message
    }
}

public struct LibraryDirectorySnapshot: Equatable, Sendable {
    public let entries: [LibraryDirectoryEntry]
    public let issues: [LibraryTraversalIssue]

    public init(entries: [LibraryDirectoryEntry], issues: [LibraryTraversalIssue]) {
        self.entries = entries
        self.issues = issues
    }
}

public enum LibraryFileSystemError: Error, Equatable, LocalizedError, Sendable {
    case unsafePath(String)
    case missing(String)
    case symbolicLink(String)
    case notDirectory(String)
    case notRegularFile(String)
    case tooLarge(path: String, maximumBytes: Int, actualBytes: Int64)
    case system(operation: String, path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path): "Unsafe Library path: \(path)"
        case .missing(let path): "Library item is missing: \(path)"
        case .symbolicLink(let path): "Symbolic links are not allowed in the Library: \(path)"
        case .notDirectory(let path): "Expected a Library directory: \(path)"
        case .notRegularFile(let path): "Expected a regular Library file: \(path)"
        case .tooLarge(let path, let maximumBytes, let actualBytes):
            "Library file \(path) is \(actualBytes) bytes; the safe limit is \(maximumBytes) bytes."
        case .system(let operation, let path, let code):
            "Library filesystem operation \(operation) failed for \(path) (errno \(code))."
        }
    }
}
