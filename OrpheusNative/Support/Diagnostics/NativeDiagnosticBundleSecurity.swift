import Darwin
import Foundation
import NativeQobuzCore

enum NativeDiagnosticBundleSecurity {
    private static let directoryMode = mode_t(0o700)
    private static let fileMode = mode_t(0o600)

    static func createPrivateDirectory(
        at url: URL,
        withIntermediateDirectories: Bool
    ) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
        try secureItem(at: url, expectedKind: .directory)
    }

    static func writePrivateFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try secureItem(at: url, expectedKind: .regularFile)
    }

    static func secureTree(at rootURL: URL) throws {
        let fileSystem = try LibraryFileSystem(rootURL: rootURL, createIfMissing: false)
        let snapshot = try fileSystem.recursiveSnapshot()
        guard snapshot.issues.isEmpty else {
            throw NativeDiagnosticBundleSecurityError.unsafeEntry(
                snapshot.issues.map(\.path.rawValue).joined(separator: ", ")
            )
        }
        try secureItem(at: rootURL, expectedKind: .directory)
        for entry in snapshot.entries {
            let url = fileSystem.displayURL(for: entry.path)
            switch entry.metadata.kind {
            case .directory:
                try secureItem(at: url, expectedKind: .directory)
            case .regularFile:
                try secureItem(at: url, expectedKind: .regularFile)
            case .hardLink, .symbolicLink, .other:
                throw NativeDiagnosticBundleSecurityError.unsafeEntry(entry.path.rawValue)
            }
        }
    }

    private static func secureItem(at url: URL, expectedKind: LibraryFileKind) throws {
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            | (expectedKind == .directory ? O_DIRECTORY : 0)
        let descriptor = url.path.withCString { open($0, flags) }
        guard descriptor >= 0 else {
            throw NativeDiagnosticBundleSecurityError.system(
                operation: "open",
                path: url.path,
                code: errno
            )
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw NativeDiagnosticBundleSecurityError.system(
                operation: "fstat",
                path: url.path,
                code: errno
            )
        }
        let actualKind: LibraryFileKind = switch status.st_mode & S_IFMT {
        case S_IFDIR: .directory
        case S_IFREG: status.st_nlink > 1 ? .hardLink : .regularFile
        case S_IFLNK: .symbolicLink
        default: .other
        }
        guard actualKind == expectedKind else {
            throw NativeDiagnosticBundleSecurityError.unsafeEntry(url.path)
        }
        let mode = expectedKind == .directory ? directoryMode : fileMode
        guard fchmod(descriptor, mode) == 0 else {
            throw NativeDiagnosticBundleSecurityError.system(
                operation: "fchmod",
                path: url.path,
                code: errno
            )
        }
    }
}

private enum NativeDiagnosticBundleSecurityError: LocalizedError {
    case unsafeEntry(String)
    case system(operation: String, path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .unsafeEntry(let path):
            "Unsafe item in diagnostic bundle: \(path)"
        case .system(let operation, let path, let code):
            "Diagnostic bundle security operation \(operation) failed for \(path) (errno \(code))."
        }
    }
}
