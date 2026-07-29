import Darwin
import Foundation

final class LibraryDescriptorRoot: @unchecked Sendable {
    let descriptor: Int32

    init(rootURL: URL, createIfMissing: Bool) throws {
        guard rootURL.isFileURL else {
            throw LibraryFileSystemError.unsafePath(rootURL.absoluteString)
        }
        descriptor = try Self.openRoot(rootURL.standardizedFileURL, createIfMissing: createIfMissing)
    }

    deinit { close(descriptor) }

    func duplicateRoot() throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let value = ".".withCString { openat(descriptor, $0, flags) }
        guard value >= 0 else {
            throw LibraryFileSystemError.system(operation: "openat-root-copy", path: ".", code: errno)
        }
        return value
    }

    func setPermissions(_ permissions: UInt16) throws {
        guard fchmod(descriptor, mode_t(permissions)) == 0 else {
            throw mappedError(operation: "fchmod-root", path: ".", code: errno)
        }
    }

    func withDirectory<T>(
        _ path: LibraryRelativePath,
        create: Bool = false,
        _ body: (Int32) throws -> T
    ) throws -> T {
        let value = try openDirectory(path.components, create: create)
        defer { close(value) }
        return try body(value)
    }

    func withParent<T>(
        of path: LibraryRelativePath,
        create: Bool = false,
        _ body: (Int32, String) throws -> T
    ) throws -> T {
        guard !path.isRoot, let leaf = path.lastComponent else {
            throw LibraryFileSystemError.unsafePath(path.rawValue)
        }
        let parent = try openDirectory(path.parent.components, create: create)
        defer { close(parent) }
        return try body(parent, leaf)
    }

    func openDirectory(_ components: [String], create: Bool) throws -> Int32 {
        var current = try duplicateRoot()
        do {
            for (index, component) in components.enumerated() {
                let displayPath = components.prefix(index + 1).joined(separator: "/")
                let child = try Self.openDirectoryComponent(
                    component,
                    in: current,
                    displayPath: displayPath,
                    create: create
                )
                close(current)
                current = child
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    private static func openDirectoryComponent(
        _ name: String,
        in parent: Int32,
        displayPath: String,
        create: Bool
    ) throws -> Int32 {
        var status = stat()
        let inspection = name.withCString { fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW) }
        if inspection != 0 {
            let code = errno
            if code == ENOENT, create {
                let result = name.withCString { mkdirat(parent, $0, mode_t(0o755)) }
                if result != 0, errno != EEXIST {
                    throw mappedError(operation: "mkdirat", path: displayPath, code: errno)
                }
            } else {
                throw mappedError(operation: "fstatat", path: displayPath, code: code)
            }
        } else {
            let kind = status.st_mode & S_IFMT
            if kind == S_IFLNK { throw LibraryFileSystemError.symbolicLink(displayPath) }
            guard kind == S_IFDIR else { throw LibraryFileSystemError.notDirectory(displayPath) }
        }

        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let child = name.withCString { openat(parent, $0, flags) }
        guard child >= 0 else {
            throw mappedError(operation: "openat-directory", path: displayPath, code: errno)
        }
        return child
    }

    private static func openRoot(_ rootURL: URL, createIfMissing: Bool) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        guard rootURL.path.hasPrefix("/") else {
            throw LibraryFileSystemError.unsafePath(rootURL.path)
        }
        let pathComponents = trustedSystemAliasNormalizedPath(rootURL.path)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        var current = "/".withCString { open($0, flags) }
        guard current >= 0 else {
            throw mappedError(operation: "open-filesystem-root", path: "/", code: errno)
        }
        var traversed: [String] = []
        do {
            for component in pathComponents {
                traversed.append(component)
                let displayPath = "/" + traversed.joined(separator: "/")
                let next = try openDirectoryComponent(
                    component,
                    in: current,
                    displayPath: displayPath,
                    create: createIfMissing
                )
                close(current)
                current = next
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    private static func trustedSystemAliasNormalizedPath(_ path: String) -> String {
        if path == "/var" || path.hasPrefix("/var/") { return "/private" + path }
        if path == "/tmp" || path.hasPrefix("/tmp/") { return "/private" + path }
        return path
    }
}

func mappedError(operation: String, path: String, code: Int32) -> LibraryFileSystemError {
    switch code {
    case ENOENT: .missing(path)
    case ELOOP: .symbolicLink(path)
    case ENOTDIR: .notDirectory(path)
    default: .system(operation: operation, path: path, code: code)
    }
}
