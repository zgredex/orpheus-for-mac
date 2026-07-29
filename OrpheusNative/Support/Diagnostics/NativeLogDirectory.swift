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
            try fileSystem.moveItem(
                at: path,
                to: LibraryRelativePath("orpheus-rejected-\(UUID().uuidString).jsonl")
            )
        }
        return try fileSystem.writableHandle(at: path, truncate: false)
    }

    func files() throws -> [NativeLogFile] {
        try fileSystem.entries(in: .root)
            .compactMap { entry -> NativeLogFile? in
                guard entry.metadata.kind == .regularFile,
                      let name = entry.path.lastComponent,
                      name.hasPrefix("orpheus-"),
                      name.hasSuffix(".jsonl")
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
}
