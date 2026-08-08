import Foundation

struct LibraryFileTransactionExecutor {
    let fileSystem: LibraryFileSystem
    private var inspector: LibraryFileStateInspector { LibraryFileStateInspector(fileSystem: fileSystem) }

    func stageOriginals(_ journal: LibraryFileTransactionJournal) throws {
        for entry in journal.entries {
            try Task.checkCancellation()
            let original = try LibraryRelativePath(entry.originalPath)
            let metadata = try fileSystem.metadata(at: original)
            if let expected = entry.originalSHA256 {
                guard let metadata else { throw LibraryFileSystemError.missing(original.rawValue) }
                try inspector.requireRegular(metadata, path: original)
                try inspector.requireDigest(expected, at: original, changedMessage: "A Library file changed after the operation was planned.")
                try fileSystem.moveItem(
                    at: original,
                    to: try LibraryRelativePath(entry.quarantinedPath)
                )
            } else if metadata != nil {
                throw NativeQobuzError.fileSystem("A new Library file appeared after the operation was planned.")
            }
        }
        LibraryFileTransactionLogger.log(
            .debug,
            "Library file transaction originals quarantined",
            journal: journal
        )
    }

    func applyFinalState(
        _ journal: LibraryFileTransactionJournal,
        mutations: [LibraryFileTransactionMutation],
        didApply: (Int) throws -> Void
    ) throws {
        guard mutations.count == journal.entries.count else {
            throw NativeQobuzError.fileSystem("The Library transaction plan changed during execution.")
        }
        for (index, pair) in zip(mutations, journal.entries).enumerated() {
            let (mutation, entry) = pair
            try Task.checkCancellation()
            switch mutation.finalState {
            case .absent:
                break
            case .data(let data):
                guard MusicFileIntegrity.sha256(of: data) == entry.finalSHA256 else {
                    throw NativeQobuzError.fileSystem("The Library replacement data changed during execution.")
                }
                try fileSystem.writeAtomically(data, to: mutation.path)
            case .stagedFile(let source, let expected):
                guard source.rawValue == entry.replacementSourcePath,
                      let metadata = try fileSystem.metadata(at: source) else {
                    throw LibraryFileSystemError.missing(source.rawValue)
                }
                try inspector.requireRegular(metadata, path: source)
                guard expected == entry.finalSHA256 else {
                    throw NativeQobuzError.fileSystem("The staged replacement does not match its journal.")
                }
                try inspector.requireDigest(
                    expected,
                    at: source,
                    changedMessage: "The staged Library replacement changed during execution."
                )
                try fileSystem.moveItem(at: source, to: mutation.path)
            }
            try didApply(index)
        }
        LibraryFileTransactionLogger.log(
            .debug,
            "Library file transaction final state applied",
            journal: journal
        )
    }

    func rollback(_ journal: LibraryFileTransactionJournal) throws {
        for entry in journal.entries.reversed() {
            try rollback(entry)
        }
    }

    func validateFinalState(_ journal: LibraryFileTransactionJournal) throws {
        for entry in journal.entries {
            let original = try LibraryRelativePath(entry.originalPath)
            if let expected = entry.finalSHA256 {
                guard let metadata = try fileSystem.metadata(at: original) else {
                    throw LibraryFileSystemError.missing(original.rawValue)
                }
                try inspector.requireRegular(metadata, path: original)
                try inspector.requireDigest(
                    expected,
                    at: original,
                    changedMessage: "A prepared Library replacement changed before commit."
                )
            } else if try fileSystem.metadata(at: original) != nil {
                throw NativeQobuzError.fileSystem("A Library file scheduled for removal reappeared before commit.")
            }
            if let sourceValue = entry.replacementSourcePath,
               try fileSystem.metadata(at: LibraryRelativePath(sourceValue)) != nil {
                throw NativeQobuzError.fileSystem("A staged Library replacement was duplicated before commit.")
            }
        }
    }

    func removeQuarantinedOriginals(_ journal: LibraryFileTransactionJournal) throws {
        for entry in journal.entries {
            let quarantined = try LibraryRelativePath(entry.quarantinedPath)
            guard let metadata = try fileSystem.metadata(at: quarantined) else { continue }
            try inspector.requireRegular(metadata, path: quarantined)
            guard let expected = entry.originalSHA256 else {
                throw NativeQobuzError.fileSystem("An unexpected quarantined Library original exists.")
            }
            try inspector.requireDigest(
                expected,
                at: quarantined,
                changedMessage: "A quarantined Library original changed before commit."
            )
            try fileSystem.removeFile(quarantined)
        }
    }

    private func rollback(_ entry: LibraryFileTransactionJournal.Entry) throws {
        let original = try LibraryRelativePath(entry.originalPath)
        let quarantined = try LibraryRelativePath(entry.quarantinedPath)
        let backup = try fileSystem.metadata(at: quarantined)
        if let expectedOriginal = entry.originalSHA256 {
            if let backup {
                try inspector.requireRegular(backup, path: quarantined)
                try inspector.requireDigest(
                    expectedOriginal,
                    at: quarantined,
                    changedMessage: "A quarantined Library original changed before rollback."
                )
                try revertFinalState(entry, at: original)
                try fileSystem.moveItem(at: quarantined, to: original)
            } else {
                guard let current = try fileSystem.metadata(at: original) else {
                    throw LibraryFileSystemError.missing(original.rawValue)
                }
                try inspector.requireRegular(current, path: original)
                try inspector.requireDigest(
                    expectedOriginal,
                    at: original,
                    changedMessage: "The original Library file could not be recovered."
                )
                try requireReplacementSourceRestored(entry)
            }
        } else {
            guard backup == nil else {
                throw NativeQobuzError.fileSystem("An unexpected quarantined Library file exists.")
            }
            try revertFinalState(entry, at: original)
        }
    }

    private func revertFinalState(
        _ entry: LibraryFileTransactionJournal.Entry,
        at original: LibraryRelativePath
    ) throws {
        guard let current = try fileSystem.metadata(at: original) else {
            try requireReplacementSourceRestored(entry)
            return
        }
        try inspector.requireRegular(current, path: original)
        guard let expectedFinal = entry.finalSHA256 else {
            throw NativeQobuzError.fileSystem("An unexpected Library file appeared during rollback.")
        }
        try inspector.requireDigest(
            expectedFinal,
            at: original,
            changedMessage: "Refused to overwrite a Library file changed outside the transaction."
        )
        if let sourceValue = entry.replacementSourcePath {
            let source = try LibraryRelativePath(sourceValue)
            guard try fileSystem.metadata(at: source) == nil else {
                throw NativeQobuzError.fileSystem("The staged replacement path was reused before rollback.")
            }
            try fileSystem.moveItem(at: original, to: source)
        } else {
            try fileSystem.removeFile(original)
        }
    }

    private func requireReplacementSourceRestored(
        _ entry: LibraryFileTransactionJournal.Entry
    ) throws {
        guard let sourceValue = entry.replacementSourcePath else { return }
        let source = try LibraryRelativePath(sourceValue)
        guard let metadata = try fileSystem.metadata(at: source),
              let expected = entry.finalSHA256 else {
            throw LibraryFileSystemError.missing(source.rawValue)
        }
        try inspector.requireRegular(metadata, path: source)
        try inspector.requireDigest(
            expected,
            at: source,
            changedMessage: "The staged Library replacement could not be recovered."
        )
    }
}
