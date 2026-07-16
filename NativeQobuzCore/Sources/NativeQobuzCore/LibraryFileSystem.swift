import Darwin
import Foundation

public final class LibraryFileSystem: @unchecked Sendable {
    public let rootURL: URL
    private let root: LibraryDescriptorRoot
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

    public func read(_ path: LibraryRelativePath) throws -> Data {
        try withReadableHandle(at: path) { try $0.readToEnd() ?? Data() }
    }

    public func readString(_ path: LibraryRelativePath) throws -> String {
        guard let value = String(data: try read(path), encoding: .utf8) else {
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

    public func withInheritedReadableDescriptor<T>(
        at path: LibraryRelativePath,
        _ body: (Int32) async throws -> T
    ) async throws -> T {
        let handle = try readableHandle(at: path)
        defer { try? handle.close() }
        let descriptor = fcntl(handle.fileDescriptor, F_DUPFD, 3)
        guard descriptor >= 0 else {
            throw mappedError(operation: "duplicate-readable-file", path: path.rawValue, code: errno)
        }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_SETFD, 0) == 0 else {
            throw mappedError(operation: "inherit-readable-file", path: path.rawValue, code: errno)
        }
        return try await body(descriptor)
    }

    public func writableHandle(
        at path: LibraryRelativePath,
        truncate: Bool,
        createParents: Bool = true
    ) throws -> FileHandle {
        try openHandle(
            at: path,
            flags: O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | (truncate ? O_TRUNC : 0),
            createParents: createParents,
            creationMode: mode_t(0o600),
            operation: "openat-write"
        )
    }

    private func openHandle(
        at path: LibraryRelativePath,
        flags: Int32,
        createParents: Bool = false,
        creationMode: mode_t? = nil,
        operation: String
    ) throws -> FileHandle {
        try root.withParent(of: path, create: createParents) { parent, leaf in
            let descriptor = leaf.withCString { name in
                if let creationMode { openat(parent, name, flags, creationMode) }
                else { openat(parent, name, flags) }
            }
            guard descriptor >= 0 else {
                throw mappedError(operation: operation, path: path.rawValue, code: errno)
            }
            do {
                try Self.requireRegularFile(descriptor, path: path)
                return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            } catch {
                close(descriptor)
                throw error
            }
        }
    }

    public func writeAtomically(_ data: Data, to path: LibraryRelativePath) throws {
        try root.withParent(of: path, create: true) { parent, leaf in
            try rejectSymbolicLink(named: leaf, in: parent, path: path)
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
        }
    }

    public func removeFile(_ path: LibraryRelativePath, ifPresent: Bool = false) throws {
        try root.withParent(of: path) { parent, leaf in
            guard let metadata = try metadata(named: leaf, in: parent, path: path) else {
                if ifPresent { return }
                throw LibraryFileSystemError.missing(path.rawValue)
            }
            if metadata.kind == .symbolicLink { throw LibraryFileSystemError.symbolicLink(path.rawValue) }
            guard metadata.kind == .regularFile else {
                throw LibraryFileSystemError.notRegularFile(path.rawValue)
            }
            let result = leaf.withCString { unlinkat(parent, $0, 0) }
            guard result == 0 else {
                throw mappedError(operation: "unlinkat", path: path.rawValue, code: errno)
            }
        }
    }

    public func replaceItem(at destination: LibraryRelativePath, with source: LibraryRelativePath) throws {
        try root.withParent(of: source) { sourceParent, sourceLeaf in
            guard let sourceMetadata = try metadata(named: sourceLeaf, in: sourceParent, path: source) else {
                throw LibraryFileSystemError.missing(source.rawValue)
            }
            if sourceMetadata.kind == .symbolicLink { throw LibraryFileSystemError.symbolicLink(source.rawValue) }
            guard sourceMetadata.kind == .regularFile else {
                throw LibraryFileSystemError.notRegularFile(source.rawValue)
            }
            try root.withParent(of: destination, create: true) { destinationParent, destinationLeaf in
                try rejectSymbolicLink(named: destinationLeaf, in: destinationParent, path: destination)
                let result = sourceLeaf.withCString { sourceName in
                    destinationLeaf.withCString { destinationName in
                        renameat(sourceParent, sourceName, destinationParent, destinationName)
                    }
                }
                guard result == 0 else {
                    throw mappedError(operation: "renameat-replace", path: destination.rawValue, code: errno)
                }
            }
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
        case S_IFREG: kind = .regularFile
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

    private func metadata(
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

    private func rejectSymbolicLink(
        named leaf: String,
        in parent: Int32,
        path: LibraryRelativePath
    ) throws {
        if try metadata(named: leaf, in: parent, path: path)?.kind == .symbolicLink {
            throw LibraryFileSystemError.symbolicLink(path.rawValue)
        }
    }

    private static func requireRegularFile(_ descriptor: Int32, path: LibraryRelativePath) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw mappedError(operation: "fstat", path: path.rawValue, code: errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
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
