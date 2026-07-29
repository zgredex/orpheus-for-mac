import Darwin
import Foundation
import NativeQobuzCore

enum NativeBoundedFileReader {
    static func readComplete(
        _ url: URL,
        maximumBytes: Int,
        followSymbolicLinks: Bool = false
    ) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max else {
            throw NativeQobuzError.fileSystem("The requested file-read limit is invalid.")
        }
        let opened = try openRegularFile(url, followSymbolicLinks: followSymbolicLinks)
        defer { close(opened.descriptor) }
        guard opened.byteCount <= Int64(maximumBytes) else {
            throw NativeQobuzError.fileSystem(
                "\(url.lastPathComponent) is \(opened.byteCount) bytes; the safe limit is \(maximumBytes) bytes."
            )
        }
        let handle = FileHandle(fileDescriptor: opened.descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw NativeQobuzError.fileSystem(
                "\(url.lastPathComponent) grew beyond the safe \(maximumBytes)-byte limit while being read."
            )
        }
        return data
    }

    static func readPrefix(
        _ url: URL,
        maximumBytes: Int,
        followSymbolicLinks: Bool = false
    ) throws -> Data {
        guard maximumBytes >= 0 else {
            throw NativeQobuzError.fileSystem("The requested file-read limit is invalid.")
        }
        let opened = try openRegularFile(url, followSymbolicLinks: followSymbolicLinks)
        defer { close(opened.descriptor) }
        return try FileHandle(
            fileDescriptor: opened.descriptor,
            closeOnDealloc: false
        ).read(upToCount: maximumBytes) ?? Data()
    }

    private static func openRegularFile(
        _ url: URL,
        followSymbolicLinks: Bool
    ) throws -> (descriptor: Int32, byteCount: Int64) {
        guard url.isFileURL else {
            throw NativeQobuzError.fileSystem("Expected a local file URL.")
        }
        let flags = O_RDONLY | O_CLOEXEC | (followSymbolicLinks ? 0 : O_NOFOLLOW)
        let descriptor = url.path.withCString { open($0, flags) }
        guard descriptor >= 0 else {
            throw NativeQobuzError.fileSystem(
                "Could not open \(url.lastPathComponent) safely (errno \(errno))."
            )
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let code = errno
            close(descriptor)
            throw NativeQobuzError.fileSystem(
                "Could not inspect \(url.lastPathComponent) (errno \(code))."
            )
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw NativeQobuzError.fileSystem("\(url.lastPathComponent) is not a regular file.")
        }
        return (descriptor, max(Int64(status.st_size), 0))
    }
}
