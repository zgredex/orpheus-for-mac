import Foundation
import NativeQobuzCore

/// Installs a sensitive file from a permission-restricted staging file, so
/// credential bytes are never present under default 0644 creation modes.
enum NativeSecureFileWriter {
    static func write(
        _ data: Data,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let staging = directory.appendingPathComponent(".credentials-\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: staging.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw NativeQobuzError.fileSystem("Could not create the protected credentials file.")
        }
        defer { try? fileManager.removeItem(at: staging) }

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
