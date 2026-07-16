import CryptoKit
import Foundation

public enum MusicFileIntegrity {
    public static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        return try sha256(of: handle)
    }

    public static func sha256(of handle: FileHandle) throws -> String {
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ fileURL: URL, expectedSHA256: String) throws -> Bool {
        try sha256(of: fileURL).caseInsensitiveCompare(expectedSHA256) == .orderedSame
    }

    public static func sha256(
        of path: LibraryRelativePath,
        in fileSystem: LibraryFileSystem
    ) throws -> String {
        let handle = try fileSystem.readableHandle(at: path)
        defer { try? handle.close() }
        return try sha256(of: handle)
    }
}
