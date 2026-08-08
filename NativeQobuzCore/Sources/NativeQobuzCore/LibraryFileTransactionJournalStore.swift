import Foundation

struct LibraryFileTransactionJournalBuilder {
    func make(_ plan: LibraryFileTransactionPlan) throws -> LibraryFileTransactionJournal {
        guard !plan.mutations.isEmpty else {
            throw NativeQobuzError.fileSystem("A Library file transaction cannot be empty.")
        }
        let directory = try LibraryRelativePath(
            LibraryFileTransactionJournal.directoryPrefix + UUID().uuidString.lowercased()
        )
        let entries = try plan.mutations.enumerated().map { index, mutation in
            let originalSHA256: String?
            switch mutation.expectedOriginal {
            case .absent: originalSHA256 = nil
            case .regularFile(let digest): originalSHA256 = digest
            }
            let finalSHA256: String?
            let sourcePath: String?
            switch mutation.finalState {
            case .absent:
                finalSHA256 = nil
                sourcePath = nil
            case .data(let data):
                finalSHA256 = MusicFileIntegrity.sha256(of: data)
                sourcePath = nil
            case .stagedFile(let source, let digest):
                finalSHA256 = digest
                sourcePath = source.rawValue
            }
            return LibraryFileTransactionJournal.Entry(
                originalPath: mutation.path.rawValue,
                quarantinedPath: try directory.appending(String(format: "%08d.original", index)).rawValue,
                originalSHA256: originalSHA256,
                finalSHA256: finalSHA256,
                replacementSourcePath: sourcePath
            )
        }
        let journal = LibraryFileTransactionJournal(
            version: 1,
            operation: plan.operation,
            directory: directory,
            phase: .staging,
            entries: entries
        )
        try journal.validate(directory: directory)
        return journal
    }
}

struct LibraryFileTransactionJournalStore {
    let fileSystem: LibraryFileSystem

    func create(_ journal: LibraryFileTransactionJournal) throws {
        try fileSystem.createDirectory(journal.directory)
        try fileSystem.setDirectoryPermissions(0o700, at: journal.directory)
        try save(journal)
        LibraryFileTransactionLogger.log(
            .info,
            "Library file transaction journal persisted",
            journal: journal
        )
    }

    func load(_ token: LibraryFileTransactionToken) throws -> LibraryFileTransactionJournal {
        guard token.root.standardizedFileURL == fileSystem.rootURL else {
            throw NativeQobuzError.fileSystem("The Library transaction token belongs to another folder.")
        }
        let journalPath = try token.directory.appending(LibraryFileTransactionJournal.filename)
        let journal = try JSONDecoder().decode(
            LibraryFileTransactionJournal.self,
            from: fileSystem.read(journalPath, maximumBytes: LibraryFileTransactionJournal.maximumBytes)
        )
        try journal.validate(directory: token.directory)
        return journal
    }

    func save(_ journal: LibraryFileTransactionJournal) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(journal)
        guard data.count <= LibraryFileTransactionJournal.maximumBytes else {
            throw NativeQobuzError.fileSystem("The Library transaction journal is too large.")
        }
        try fileSystem.writeAtomically(data, to: journal.journalPath)
    }

    func remove(_ journal: LibraryFileTransactionJournal) throws {
        try fileSystem.removeFile(journal.journalPath, ifPresent: true)
        guard try fileSystem.removeEmptyDirectory(journal.directory) else {
            throw NativeQobuzError.fileSystem(
                "The Library transaction quarantine contains unexpected items and was preserved."
            )
        }
    }

    func candidates() throws -> [LibraryDirectoryEntry] {
        try fileSystem.entries(in: .root).filter {
            $0.path.lastComponent?.hasPrefix(LibraryFileTransactionJournal.directoryPrefix) == true
        }.sorted { $0.path.rawValue < $1.path.rawValue }
    }

    func discardUnpublishedDirectory(_ directory: LibraryRelativePath) throws {
        let entries = try fileSystem.entries(in: directory)
        if entries.isEmpty {
            guard try fileSystem.removeEmptyDirectory(directory) else {
                throw NativeQobuzError.fileSystem("An empty Library transaction folder could not be removed.")
            }
            return
        }
        guard entries.count == 1, let temporary = entries.first,
              temporary.metadata.kind == .regularFile,
              isAtomicJournalTemporary(temporary.path.lastComponent) else {
            throw NativeQobuzError.fileSystem(
                "An unrecognized Library transaction folder exists at \(directory.rawValue)."
            )
        }
        try fileSystem.removeFile(temporary.path)
        guard try fileSystem.removeEmptyDirectory(directory) else {
            throw NativeQobuzError.fileSystem("An interrupted Library journal folder could not be removed.")
        }
    }

    private func isAtomicJournalTemporary(_ filename: String?) -> Bool {
        let prefix = ".\(LibraryFileTransactionJournal.filename)."
        let suffix = ".partial"
        guard let filename,
              filename.hasPrefix(prefix),
              filename.hasSuffix(suffix) else { return false }
        let start = filename.index(filename.startIndex, offsetBy: prefix.count)
        let end = filename.index(filename.endIndex, offsetBy: -suffix.count)
        return UUID(uuidString: String(filename[start..<end])) != nil
    }
}
