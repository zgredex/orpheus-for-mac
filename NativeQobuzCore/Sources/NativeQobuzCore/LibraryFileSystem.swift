import Darwin
import Foundation

public final class LibraryFileSystem: @unchecked Sendable {
    public let rootURL: URL
    let root: LibraryDescriptorRoot
    private lazy var enumerator = LibraryDirectoryEnumerator(root: root)

    public init(rootURL: URL, createIfMissing: Bool = true) throws {
        self.rootURL = rootURL.standardizedFileURL
        root = try LibraryDescriptorRoot(rootURL: self.rootURL, createIfMissing: createIfMissing)
    }

    public func relativePath(for url: URL, allowingRoot: Bool = false) throws -> LibraryRelativePath {
        try LibraryRelativePath(
            QobuzPathSafety.relativePath(of: url, in: rootURL, allowingRoot: allowingRoot)
        )
    }

    public func displayURL(for path: LibraryRelativePath) -> URL {
        path.isRoot ? rootURL : rootURL.appendingPathComponent(path.rawValue)
    }

    public func createDirectory(_ path: LibraryRelativePath) throws {
        try root.withDirectory(path, create: true) { _ in }
    }

    public func setRootPermissions(_ permissions: UInt16) throws {
        try root.setPermissions(permissions)
    }

    public func metadata(at path: LibraryRelativePath) throws -> LibraryFileMetadata? {
        if path.isRoot {
            return try root.withDirectory(path) { descriptor in
                var status = stat()
                guard fstat(descriptor, &status) == 0 else {
                    throw mappedError(operation: "fstat-root", path: ".", code: errno)
                }
                return Self.metadata(from: status)
            }
        }
        do {
            return try root.withParent(of: path) { parent, leaf in
                var status = stat()
                let result = leaf.withCString { fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW) }
                if result != 0, errno == ENOENT { return nil }
                guard result == 0 else {
                    throw mappedError(operation: "fstatat", path: path.rawValue, code: errno)
                }
                return Self.metadata(from: status)
            }
        } catch LibraryFileSystemError.missing {
            return nil
        }
    }

    public func read(
        _ path: LibraryRelativePath,
        maximumBytes: Int = 128 * 1_024 * 1_024
    ) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max else {
            throw LibraryFileSystemError.unsafePath(path.rawValue)
        }
        return try withReadableHandle(at: path) { handle in
            let metadata = try Self.regularFileMetadata(handle.fileDescriptor, path: path)
            guard metadata.byteCount <= Int64(maximumBytes) else {
                throw LibraryFileSystemError.tooLarge(
                    path: path.rawValue,
                    maximumBytes: maximumBytes,
                    actualBytes: metadata.byteCount
                )
            }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else {
                throw LibraryFileSystemError.tooLarge(
                    path: path.rawValue,
                    maximumBytes: maximumBytes,
                    actualBytes: Int64(data.count)
                )
            }
            return data
        }
    }

    public func readString(
        _ path: LibraryRelativePath,
        maximumBytes: Int = 128 * 1_024 * 1_024
    ) throws -> String {
        guard let value = String(data: try read(path, maximumBytes: maximumBytes), encoding: .utf8) else {
            throw LibraryFileSystemError.notRegularFile(path.rawValue)
        }
        return value
    }

    public func readableHandle(at path: LibraryRelativePath) throws -> FileHandle {
        try openHandle(
            at: path,
            flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC,
            operation: "openat-read"
        )
    }

    public func withReadableHandle<T>(
        at path: LibraryRelativePath,
        _ body: (FileHandle) throws -> T
    ) throws -> T {
        let handle = try readableHandle(at: path)
        defer { try? handle.close() }
        return try body(handle)
    }

    public func withReadableDescriptor<T>(
        at path: LibraryRelativePath,
        _ body: (Int32) async throws -> T
    ) async throws -> T {
        let handle = try readableHandle(at: path)
        defer { try? handle.close() }
        return try await body(handle.fileDescriptor)
    }

    public func writableHandle(
        at path: LibraryRelativePath,
        truncate: Bool,
        createParents: Bool = true
    ) throws -> FileHandle {
        if truncate {
            if createParents { try createDirectory(path.parent) }
            if let metadata = try metadata(at: path) {
                try Self.requireUnsharedRegularFile(metadata, path: path)
                try removeFile(path)
            }
            return try openHandle(
                at: path,
                flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                createParents: createParents,
                creationMode: mode_t(0o600),
                operation: "openat-truncate-replacement"
            )
        }
        return try openHandle(
            at: path,
            flags: O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            createParents: createParents,
            creationMode: mode_t(0o600),
            operation: "openat-write"
        )
    }

    func openHandle(
        at path: LibraryRelativePath,
        flags: Int32,
        createParents: Bool = false,
        creationMode: mode_t? = nil,
        operation: String
    ) throws -> FileHandle {
        try root.withParent(of: path, create: createParents) { parent, leaf in
            let existingMetadata = try metadata(named: leaf, in: parent, path: path)
            if let metadata = existingMetadata {
                try Self.requireUnsharedRegularFile(metadata, path: path)
            } else if creationMode == nil {
                throw LibraryFileSystemError.missing(path.rawValue)
            }
            let descriptor = leaf.withCString { name -> Int32 in
                let nonblockingFlags = flags | O_NONBLOCK
                if let creationMode {
                    return openat(parent, name, nonblockingFlags, creationMode)
                }
                return openat(parent, name, nonblockingFlags)
            }
            guard descriptor >= 0 else {
                throw mappedError(operation: operation, path: path.rawValue, code: errno)
            }
            do {
                try Self.requireRegularFile(descriptor, path: path)
                if existingMetadata == nil, flags & O_CREAT != 0 {
                    try LibraryDirectoryDurability.synchronize(
                        [(parent, path.parent.rawValue)],
                        operation: "fsync-parent-after-file-creation"
                    )
                }
                return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            } catch {
                close(descriptor)
                throw error
            }
        }
    }

    public func writeAtomically(_ data: Data, to path: LibraryRelativePath) throws {
        try root.withParent(of: path, create: true) { parent, leaf in
            try requireSafeReplacement(named: leaf, in: parent, path: path)
            let temporary = ".\(leaf).\(UUID().uuidString).partial"
            let descriptor = temporary.withCString {
                openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            }
            guard descriptor >= 0 else {
                throw mappedError(operation: "openat-atomic", path: path.rawValue, code: errno)
            }
            var shouldRemove = true
            defer {
                close(descriptor)
                if shouldRemove { temporary.withCString { _ = unlinkat(parent, $0, 0) } }
            }
            try Self.writeAll(data, to: descriptor, path: path)
            guard fsync(descriptor) == 0 else {
                throw mappedError(operation: "fsync", path: path.rawValue, code: errno)
            }
            let renamed = temporary.withCString { source in
                leaf.withCString { destination in renameat(parent, source, parent, destination) }
            }
            guard renamed == 0 else {
                throw mappedError(operation: "renameat", path: path.rawValue, code: errno)
            }
            shouldRemove = false
            try LibraryDirectoryDurability.synchronize(
                [(parent, path.parent.rawValue)],
                operation: "fsync-parent-after-atomic-write"
            )
        }
    }

    public func recursiveSnapshot(from path: LibraryRelativePath = .root) throws -> LibraryDirectorySnapshot {
        try enumerator.recursiveSnapshot(from: path)
    }

    public func entries(in path: LibraryRelativePath) throws -> [LibraryDirectoryEntry] {
        try enumerator.immediateEntries(in: path)
    }

    static func metadata(from status: stat) -> LibraryFileMetadata {
        let kind: LibraryFileKind
        switch status.st_mode & S_IFMT {
        case S_IFREG: kind = status.st_nlink > 1 ? .hardLink : .regularFile
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symbolicLink
        default: kind = .other
        }
        let seconds = TimeInterval(status.st_mtimespec.tv_sec)
        let nanoseconds = TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        return LibraryFileMetadata(
            kind: kind,
            byteCount: max(Int64(status.st_size), 0),
            modificationDate: Date(timeIntervalSince1970: seconds + nanoseconds)
        )
    }

    func metadata(
        named leaf: String,
        in parent: Int32,
        path: LibraryRelativePath
    ) throws -> LibraryFileMetadata? {
        var status = stat()
        let result = leaf.withCString { fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW) }
        if result != 0, errno == ENOENT { return nil }
        guard result == 0 else {
            throw mappedError(operation: "fstatat", path: path.rawValue, code: errno)
        }
        return Self.metadata(from: status)
    }

    func requireSafeReplacement(
        named leaf: String,
        in parent: Int32,
        path: LibraryRelativePath
    ) throws {
        guard let metadata = try metadata(named: leaf, in: parent, path: path) else { return }
        try Self.requireUnsharedRegularFile(metadata, path: path)
    }

    private static func requireRegularFile(_ descriptor: Int32, path: LibraryRelativePath) throws {
        _ = try regularFileMetadata(descriptor, path: path)
    }

    private static func regularFileMetadata(
        _ descriptor: Int32,
        path: LibraryRelativePath
    ) throws -> LibraryFileMetadata {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw mappedError(operation: "fstat", path: path.rawValue, code: errno)
        }
        let metadata = metadata(from: status)
        try requireUnsharedRegularFile(metadata, path: path)
        return metadata
    }

    private static func requireUnsharedRegularFile(
        _ metadata: LibraryFileMetadata,
        path: LibraryRelativePath
    ) throws {
        switch metadata.kind {
        case .regularFile:
            return
        case .symbolicLink:
            throw LibraryFileSystemError.symbolicLink(path.rawValue)
        case .hardLink:
            throw LibraryFileSystemError.hardLink(path.rawValue)
        case .directory, .other:
            throw LibraryFileSystemError.notRegularFile(path.rawValue)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, path: LibraryRelativePath) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var address = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, address, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw mappedError(operation: "write", path: path.rawValue, code: errno)
                }
                address = address.advanced(by: count)
                remaining -= count
            }
        }
    }
}
