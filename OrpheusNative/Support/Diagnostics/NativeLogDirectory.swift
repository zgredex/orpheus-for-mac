import Foundation
import NativeQobuzCore

struct NativeLogFile: Equatable, Sendable {
    let path: LibraryRelativePath
    let metadata: LibraryFileMetadata
}

/// Descriptor-relative storage for persistent diagnostic files.
/// Log readers, rotation, clearing, and export all share this boundary.
struct NativeLogDirectory: Sendable {
    private static let currentName = "orpheus-current.jsonl"
    private let fileSystem: LibraryFileSystem

    init(directoryURL: URL) throws {
        fileSystem = try LibraryFileSystem(rootURL: directoryURL)
        try fileSystem.setRootPermissions(0o700)
    }

    func openCurrentFile() throws -> FileHandle {
        let path = try LibraryRelativePath(Self.currentName)
        if let metadata = try fileSystem.metadata(at: path), metadata.kind != .regularFile {
            try fileSystem.quarantineItem(
                at: path,
                to: LibraryRelativePath("orpheus-rejected-\(UUID().uuidString).jsonl")
            )
        }
        try repairInterruptedTail(at: path)
        return try fileSystem.writableHandle(at: path, truncate: false)
    }

    /// A process may terminate between writing JSON bytes and the terminating
    /// newline. Drop only that incomplete tail before the next append so two
    /// independent records can never be fused into one corrupt JSONL line.
    private func repairInterruptedTail(at path: LibraryRelativePath) throws {
        guard let metadata = try fileSystem.metadata(at: path), metadata.byteCount > 0 else { return }
        let maximumBytes = 64 * 1_024 * 1_024
        guard metadata.byteCount <= Int64(maximumBytes) else {
            try fileSystem.moveItem(
                at: path,
                to: LibraryRelativePath("orpheus-rejected-oversized-\(UUID().uuidString).jsonl")
            )
            return
        }
        let data = try fileSystem.read(path, maximumBytes: maximumBytes)
        guard data.last != 0x0A else { return }
        let validLength = data.lastIndex(of: 0x0A).map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
        try fileSystem.writeAtomically(Data(data.prefix(validLength)), to: path)
    }

    func files() throws -> [NativeLogFile] {
        try diagnosticFiles(includeRejected: false)
    }

    /// Clearing is explicit destructive intent, so it also removes regular
    /// quarantined log artifacts. Reads, rotation, and export deliberately do
    /// not treat those untrusted files as valid JSONL archives.
    func clearableFiles() throws -> [NativeLogFile] {
        try diagnosticFiles(includeRejected: true)
    }

    func rotateCurrent(to archiveName: String) throws {
        try fileSystem.moveItem(
            at: LibraryRelativePath(Self.currentName),
            to: LibraryRelativePath(archiveName)
        )
    }

    func remove(_ file: NativeLogFile) throws {
        try fileSystem.removeFile(file.path)
    }

    func withReadableHandle<T>(
        for file: NativeLogFile,
        _ body: (FileHandle) throws -> T
    ) throws -> T {
        try fileSystem.withReadableHandle(at: file.path, body)
    }

    func copy(
        _ files: [NativeLogFile],
        to destination: URL,
        maximumFileBytes: Int64
    ) throws {
        let destinationFileSystem = try LibraryFileSystem(rootURL: destination)
        try destinationFileSystem.setRootPermissions(0o700)
        for file in files {
            guard file.metadata.byteCount <= maximumFileBytes else {
                throw LibraryFileSystemError.tooLarge(
                    path: file.path.rawValue,
                    maximumBytes: Int(clamping: maximumFileBytes),
                    actualBytes: file.metadata.byteCount
                )
            }
            try withReadableHandle(for: file) { source in
                let target = try destinationFileSystem.writableHandle(at: file.path, truncate: true)
                defer { try? target.close() }
                var copied: Int64 = 0
                while let chunk = try source.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                    copied += Int64(chunk.count)
                    guard copied <= maximumFileBytes else {
                        throw LibraryFileSystemError.tooLarge(
                            path: file.path.rawValue,
                            maximumBytes: Int(clamping: maximumFileBytes),
                            actualBytes: copied
                        )
                    }
                    try target.write(contentsOf: chunk)
                }
                try target.synchronize()
            }
        }
    }

    private func diagnosticFiles(includeRejected: Bool) throws -> [NativeLogFile] {
        try fileSystem.entries(in: .root)
            .compactMap { entry -> NativeLogFile? in
                guard entry.metadata.kind == .regularFile,
                      let name = entry.path.lastComponent,
                      name.hasPrefix("orpheus-"),
                      name.hasSuffix(".jsonl"),
                      includeRejected || !name.hasPrefix("orpheus-rejected-")
                else { return nil }
                return NativeLogFile(path: entry.path, metadata: entry.metadata)
            }
            .sorted {
                if $0.metadata.modificationDate == $1.metadata.modificationDate {
                    return $0.path.rawValue < $1.path.rawValue
                }
                return $0.metadata.modificationDate < $1.metadata.modificationDate
            }
    }
}
