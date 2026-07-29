import CryptoKit
import Foundation

struct LibraryFileCopyResult: Equatable {
    let byteCount: Int64
    let sha256: String
}

struct LibraryFileCopier {
    private let chunkSize = 1_048_576

    func copy(
        _ path: LibraryRelativePath,
        from source: LibraryFileSystem,
        to destination: LibraryFileSystem
    ) throws -> LibraryFileCopyResult {
        let input = try source.readableHandle(at: path)
        defer { try? input.close() }
        let output = try destination.exclusiveWritableHandle(at: path)
        var completed = false
        defer {
            try? output.close()
            if !completed { try? destination.removeFile(path, ifPresent: true) }
        }

        var digest = SHA256()
        var byteCount: Int64 = 0
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
            try output.write(contentsOf: chunk)
            byteCount += Int64(chunk.count)
        }
        try output.synchronize()
        try output.close()
        let sourceDigest = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let destinationDigest = try MusicFileIntegrity.sha256(of: path, in: destination)
        guard sourceDigest.caseInsensitiveCompare(destinationDigest) == .orderedSame else {
            throw NativeQobuzError.fileSystem("Copied Library file failed SHA-256 verification: \(path.rawValue)")
        }
        completed = true
        return LibraryFileCopyResult(byteCount: byteCount, sha256: destinationDigest)
    }
}
