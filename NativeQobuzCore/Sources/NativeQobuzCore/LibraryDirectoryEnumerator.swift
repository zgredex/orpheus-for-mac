import Darwin
import Foundation

struct LibraryDirectoryEnumerator {
    let root: LibraryDescriptorRoot

    func recursiveSnapshot(from path: LibraryRelativePath) throws -> LibraryDirectorySnapshot {
        try root.withDirectory(path) { descriptor in
            var entries: [LibraryDirectoryEntry] = []
            var issues: [LibraryTraversalIssue] = []
            try enumerate(
                descriptor: descriptor,
                relativeDirectory: path,
                entries: &entries,
                issues: &issues
            )
            entries.sort { $0.path.rawValue < $1.path.rawValue }
            issues.sort { $0.path.rawValue < $1.path.rawValue }
            return LibraryDirectorySnapshot(entries: entries, issues: issues)
        }
    }

    func immediateEntries(in path: LibraryRelativePath) throws -> [LibraryDirectoryEntry] {
        try root.withDirectory(path) { descriptor in
            var entries: [LibraryDirectoryEntry] = []
            try readEntries(descriptor: descriptor, relativeDirectory: path) { entry, _ in
                entries.append(entry)
            }
            return entries.sorted { $0.path.rawValue < $1.path.rawValue }
        }
    }

    private func enumerate(
        descriptor: Int32,
        relativeDirectory: LibraryRelativePath,
        entries: inout [LibraryDirectoryEntry],
        issues: inout [LibraryTraversalIssue]
    ) throws {
        try readEntries(descriptor: descriptor, relativeDirectory: relativeDirectory) { entry, name in
            entries.append(entry)
            if entry.metadata.kind == .symbolicLink {
                issues.append(LibraryTraversalIssue(
                    path: entry.path,
                    message: "Symbolic link ignored; its target was not opened."
                ))
                return
            }
            if entry.metadata.kind == .hardLink {
                issues.append(LibraryTraversalIssue(
                    path: entry.path,
                    message: "Hard-linked file ignored; shared inode contents were not opened."
                ))
                return
            }
            guard entry.metadata.kind == .directory else { return }
            let child = name.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard child >= 0 else {
                issues.append(LibraryTraversalIssue(
                    path: entry.path,
                    message: mappedError(
                        operation: "openat-enumeration",
                        path: entry.path.rawValue,
                        code: errno
                    ).localizedDescription
                ))
                return
            }
            defer { close(child) }
            do {
                try enumerate(
                    descriptor: child,
                    relativeDirectory: entry.path,
                    entries: &entries,
                    issues: &issues
                )
            } catch {
                issues.append(LibraryTraversalIssue(path: entry.path, message: error.localizedDescription))
            }
        }
    }

    private func readEntries(
        descriptor: Int32,
        relativeDirectory: LibraryRelativePath,
        visit: (LibraryDirectoryEntry, String) throws -> Void
    ) throws {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw mappedError(operation: "duplicate-directory", path: relativeDirectory.rawValue, code: errno)
        }
        guard let stream = fdopendir(duplicate) else {
            let code = errno
            close(duplicate)
            throw mappedError(operation: "fdopendir", path: relativeDirectory.rawValue, code: code)
        }
        defer { closedir(stream) }

        errno = 0
        while let pointer = readdir(stream) {
            let name = withUnsafePointer(to: &pointer.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            let path = try relativeDirectory.appending(name)
            var status = stat()
            let result = name.withCString { fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW) }
            guard result == 0 else {
                throw mappedError(operation: "fstatat-enumeration", path: path.rawValue, code: errno)
            }
            try visit(
                LibraryDirectoryEntry(path: path, metadata: LibraryFileSystem.metadata(from: status)),
                name
            )
            errno = 0
        }
        if errno != 0 {
            throw mappedError(operation: "readdir", path: relativeDirectory.rawValue, code: errno)
        }
    }
}
