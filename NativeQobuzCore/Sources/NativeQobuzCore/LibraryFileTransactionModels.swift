import Foundation

enum LibraryFileExpectedState: Equatable, Sendable {
    case absent
    case regularFile(sha256: String)
}

enum LibraryFileFinalState: Equatable, Sendable {
    case absent
    case data(Data)
    case stagedFile(path: LibraryRelativePath, sha256: String)
}

struct LibraryFileTransactionMutation: Equatable, Sendable {
    let path: LibraryRelativePath
    let expectedOriginal: LibraryFileExpectedState
    let finalState: LibraryFileFinalState

    static func capture(
        path: LibraryRelativePath,
        finalState: LibraryFileFinalState,
        in fileSystem: LibraryFileSystem
    ) throws -> Self {
        let inspector = LibraryFileStateInspector(fileSystem: fileSystem)
        let expectedOriginal = try inspector.expectedState(at: path)
        if case .stagedFile(let source, let expectedSHA256) = finalState {
            guard source != path, let metadata = try fileSystem.metadata(at: source) else {
                throw LibraryFileSystemError.missing(source.rawValue)
            }
            try inspector.requireRegular(metadata, path: source)
            try inspector.requireDigest(
                expectedSHA256,
                at: source,
                changedMessage: "The staged Library file changed before the transaction."
            )
        }
        return Self(path: path, expectedOriginal: expectedOriginal, finalState: finalState)
    }
}

struct LibraryFileTransactionPlan: Equatable, Sendable {
    let operation: String
    let mutations: [LibraryFileTransactionMutation]
}

struct LibraryFileTransactionToken: Equatable, Sendable {
    let root: URL
    let directory: LibraryRelativePath

    func fileSystem() throws -> LibraryFileSystem {
        try LibraryFileSystem(rootURL: root, createIfMissing: false)
    }
}

struct LibraryFileTransactionJournal: Codable {
    static let directoryPrefix = ".orpheus-file-transaction-"
    static let filename = ".journal.json"
    static let maximumBytes = 16 * 1_024 * 1_024

    enum Phase: String, Codable { case staging, prepared, committing }

    struct Entry: Codable {
        let originalPath: String
        let quarantinedPath: String
        let originalSHA256: String?
        let finalSHA256: String?
        let replacementSourcePath: String?
    }

    let version: Int
    let operation: String
    let directory: LibraryRelativePath
    var phase: Phase
    let entries: [Entry]

    var journalPath: LibraryRelativePath {
        get throws { try directory.appending(Self.filename) }
    }

    func validate(directory expectedDirectory: LibraryRelativePath) throws {
        guard version == 1,
              directory == expectedDirectory,
              let name = directory.lastComponent,
              name.hasPrefix(Self.directoryPrefix),
              UUID(uuidString: String(name.dropFirst(Self.directoryPrefix.count))) != nil,
              validOperation(operation),
              !entries.isEmpty else {
            throw invalid()
        }
        var originals = Set<LibraryRelativePath>()
        var quarantined = Set<LibraryRelativePath>()
        var sources = Set<LibraryRelativePath>()
        for (index, entry) in entries.enumerated() {
            let original = try LibraryRelativePath(entry.originalPath)
            let staged = try LibraryRelativePath(entry.quarantinedPath)
            let expectedStage = try directory.appending(String(format: "%08d.original", index))
            let source = try entry.replacementSourcePath.map(LibraryRelativePath.init)
            guard !original.isRoot,
                  !usesReservedDirectory(original),
                  staged == expectedStage,
                  originals.insert(original).inserted,
                  quarantined.insert(staged).inserted,
                  entry.originalSHA256.map(validDigest) ?? true,
                  entry.finalSHA256.map(validDigest) ?? true,
                  entry.finalSHA256 != nil || source == nil else {
                throw invalid()
            }
            if let source {
                guard !source.isRoot,
                      !usesReservedDirectory(source),
                      source != original,
                      sources.insert(source).inserted else {
                    throw invalid()
                }
            }
        }
        guard sources.isDisjoint(with: originals) else { throw invalid() }
    }

    private func validOperation(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-"
        }
    }

    private func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private func usesReservedDirectory(_ path: LibraryRelativePath) -> Bool {
        path.components.contains { $0.hasPrefix(Self.directoryPrefix) }
    }

    private func invalid() -> NativeQobuzError {
        .fileSystem("The Library file transaction recovery journal is invalid.")
    }
}
