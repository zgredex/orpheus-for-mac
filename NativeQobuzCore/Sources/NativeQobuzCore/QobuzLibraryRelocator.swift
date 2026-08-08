import Foundation

struct QobuzLibraryRelocator: Sendable {
    private let scanner: any QobuzArchiveScanning
    private let copier: LibraryFileCopier

    init(
        scanner: any QobuzArchiveScanning,
        copier: LibraryFileCopier = LibraryFileCopier()
    ) {
        self.scanner = scanner
        self.copier = copier
    }

    func relocate(
        from sourceURL: URL,
        to destinationURL: URL,
        snapshot: QobuzArchiveSnapshot
    ) async throws -> QobuzLibraryRelocationResult {
        let sourceURL = sourceURL.standardizedFileURL
        let destinationURL = destinationURL.standardizedFileURL
        try validateRoots(source: sourceURL, destination: destinationURL)
        guard snapshot.problemCount == 0 else {
            throw NativeQobuzError.fileSystem(
                "Repair or prune all Library problems before relocating it."
            )
        }
        let operationID = UUID().uuidString
        let metadata = [
            "libraryRelocationID": operationID,
            "sourceRoot": sourceURL.path,
            "destinationRoot": destinationURL.path
        ]
        qobuzLog.notice("library.relocation", "Library relocation started", metadata: metadata)

        let source = try LibraryFileSystem(rootURL: sourceURL, createIfMissing: false)
        let destination = try LibraryFileSystem(rootURL: destinationURL)
        guard try destination.entries(in: .root).isEmpty else {
            throw NativeQobuzError.fileSystem("The relocation destination must be empty.")
        }
        let assets = try QobuzManagedLibraryAssets(snapshot: snapshot, fileSystem: source)
        var copied: [LibraryRelativePath] = []
        var attemptedDirectories = Set<LibraryRelativePath>()
        var copiedBytes: Int64 = 0
        do {
            for (offset, path) in assets.files.enumerated() {
                try Task.checkCancellation()
                attemptedDirectories.formUnion(path.ancestorDirectories)
                let result = try copier.copy(path, from: source, to: destination)
                copied.append(path)
                copiedBytes += result.byteCount
                qobuzLog.info(
                    "library.relocation.file",
                    "Library asset copied and verified",
                    metadata: metadata.merging([
                        "assetPath": path.rawValue,
                        "assetBytes": String(result.byteCount),
                        "assetSHA256": result.sha256,
                        "fileIndex": String(offset + 1),
                        "fileCount": String(assets.files.count)
                    ]) { _, new in new }
                )
            }
            let relocated = try await scanner.scan(root: destinationURL)
            try validate(relocated: relocated, against: snapshot)
            qobuzLog.notice(
                "library.relocation",
                "Library relocation copy verified",
                metadata: metadata.merging([
                    "fileCount": String(copied.count),
                    "byteCount": String(copiedBytes),
                    "trackCount": String(relocated.tracks.count)
                ]) { _, new in new }
            )
            return QobuzLibraryRelocationResult(
                snapshot: relocated,
                copiedFileCount: copied.count,
                copiedByteCount: copiedBytes
            )
        } catch {
            qobuzLog.error(
                "library.relocation",
                "Library relocation failed; destination cleanup started",
                metadata: metadata.merging(["copiedFileCount": String(copied.count)]) { _, new in new },
                error: error
            )
            cleanup(copied, attemptedDirectories: attemptedDirectories, in: destination)
            throw error
        }
    }

    private func validateRoots(source: URL, destination: URL) throws {
        guard source != destination,
              !QobuzPathSafety.isContained(destination, in: source),
              !QobuzPathSafety.isContained(source, in: destination) else {
            throw NativeQobuzError.fileSystem(
                "The relocation destination cannot be the current Library or contain it."
            )
        }
    }

    private func validate(
        relocated: QobuzArchiveSnapshot,
        against source: QobuzArchiveSnapshot
    ) throws {
        guard relocated.problemCount == 0,
              relocated.collections == source.collections,
              Self.trackSignatures(relocated) == Self.trackSignatures(source) else {
            throw NativeQobuzError.fileSystem(
                "The relocated Library did not match the verified source index."
            )
        }
    }

    private static func trackSignatures(_ snapshot: QobuzArchiveSnapshot) -> Set<String> {
        Set(snapshot.tracks.map {
            "\($0.relativePath)|\($0.qobuzTrackID)|\($0.qobuzAlbumID)|\($0.formatID)|\($0.expectedSHA256.lowercased())"
        })
    }

    private func cleanup(
        _ paths: [LibraryRelativePath],
        attemptedDirectories: Set<LibraryRelativePath>,
        in fileSystem: LibraryFileSystem
    ) {
        for path in paths.reversed() { try? fileSystem.removeFile(path, ifPresent: true) }
        let directories = attemptedDirectories.sorted {
            $0.components.count > $1.components.count
        }
        for directory in directories { _ = try? fileSystem.removeEmptyDirectory(directory) }
    }
}
