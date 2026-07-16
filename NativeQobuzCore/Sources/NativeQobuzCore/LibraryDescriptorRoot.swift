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
        let value = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard value >= 0 else {
            throw LibraryFileSystemError.system(operation: "duplicate-root", path: ".", code: errno)
        }
        return value
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
                let child = try openDirectoryComponent(
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

    private func openDirectoryComponent(
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
        let direct = rootURL.path.withCString { open($0, flags) }
        if direct >= 0 { return direct }

        let directError = errno
        guard directError == ENOENT, createIfMissing else {
            throw mappedError(operation: "open-root", path: rootURL.path, code: directError)
        }

        var missing: [String] = []
        var ancestor = rootURL
        var ancestorDescriptor: Int32 = -1
        while ancestor.path != "/" {
            missing.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
            ancestorDescriptor = ancestor.path.withCString { open($0, flags) }
            if ancestorDescriptor >= 0 { break }
            let code = errno
            guard code == ENOENT else {
                throw mappedError(operation: "open-root-parent", path: ancestor.path, code: code)
            }
        }
        if ancestorDescriptor < 0 {
            ancestorDescriptor = "/".withCString { open($0, flags) }
        }
        guard ancestorDescriptor >= 0 else {
            throw mappedError(operation: "open-root-parent", path: ancestor.path, code: errno)
        }

        var current = ancestorDescriptor
        do {
            for (index, component) in missing.enumerated() {
                let displayPath = missing.prefix(index + 1).joined(separator: "/")
                let created = component.withCString { mkdirat(current, $0, mode_t(0o755)) }
                if created != 0, errno != EEXIST {
                    throw mappedError(operation: "mkdirat-root", path: displayPath, code: errno)
                }
                let next = component.withCString { openat(current, $0, flags) }
                guard next >= 0 else {
                    throw mappedError(operation: "openat-root", path: displayPath, code: errno)
                }
                close(current)
                current = next
            }
            return current
        } catch {
            close(current)
            throw error
        }
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
