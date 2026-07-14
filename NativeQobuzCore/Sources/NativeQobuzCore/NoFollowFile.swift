import Darwin
import Foundation

enum NoFollowFileError: Error {
    case missing
    case symbolicLink
    case notRegular
    case system(Int32)
}

/// Opens resumable state with O_NOFOLLOW and validates the opened descriptor,
/// closing the check/open race that exists with URL resource-value inspection.
enum NoFollowFile {
    static func size(at url: URL) throws -> Int64 {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw mappedErrno() }
        defer { close(descriptor) }
        return try regularFileSize(descriptor)
    }

    static func writableHandle(at url: URL, truncate: Bool) throws -> FileHandle {
        let flags = O_WRONLY | O_CREAT | O_NOFOLLOW | (truncate ? O_TRUNC : 0)
        let descriptor = url.path.withCString { open($0, flags, mode_t(0o600)) }
        guard descriptor >= 0 else { throw mappedErrno() }
        do {
            _ = try regularFileSize(descriptor)
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func regularFileSize(_ descriptor: Int32) throws -> Int64 {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw NoFollowFileError.system(errno) }
        guard status.st_mode & S_IFMT == S_IFREG else { throw NoFollowFileError.notRegular }
        return max(Int64(status.st_size), 0)
    }

    private static func mappedErrno() -> NoFollowFileError {
        switch errno {
        case ENOENT: .missing
        case ELOOP: .symbolicLink
        default: .system(errno)
        }
    }
}
