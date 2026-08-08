import Darwin
import Foundation

public extension LibraryFileSystem {
    func exclusiveWritableHandle(at path: LibraryRelativePath) throws -> FileHandle {
        try openHandle(
            at: path,
            flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            createParents: true,
            creationMode: mode_t(0o600),
            operation: "openat-exclusive-write"
        )
    }

    @discardableResult
    func removeEmptyDirectory(_ path: LibraryRelativePath, ifPresent: Bool = true) throws -> Bool {
        guard !path.isRoot else { throw LibraryFileSystemError.unsafePath(path.rawValue) }
        guard let metadata = try metadata(at: path) else {
            if ifPresent { return false }
            throw LibraryFileSystemError.missing(path.rawValue)
        }
        if metadata.kind == .symbolicLink { throw LibraryFileSystemError.symbolicLink(path.rawValue) }
        if metadata.kind == .hardLink { throw LibraryFileSystemError.hardLink(path.rawValue) }
        guard metadata.kind == .directory else { throw LibraryFileSystemError.notDirectory(path.rawValue) }
        return try root.withParent(of: path) { parent, leaf in
            let result = leaf.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
            if result != 0, errno == ENOTEMPTY || errno == EEXIST { return false }
            guard result == 0 else {
                throw mappedError(operation: "unlinkat-directory", path: path.rawValue, code: errno)
            }
            try LibraryDirectoryDurability.synchronize(
                [(parent, path.parent.rawValue)],
                operation: "fsync-parent-after-directory-removal"
            )
            return true
        }
    }

    func setDirectoryPermissions(_ permissions: UInt16, at path: LibraryRelativePath) throws {
        guard !path.isRoot else {
            try setRootPermissions(permissions)
            return
        }
        try root.withDirectory(path) { descriptor in
            guard fchmod(descriptor, mode_t(permissions)) == 0 else {
                throw mappedError(operation: "fchmod-directory", path: path.rawValue, code: errno)
            }
        }
    }
}
