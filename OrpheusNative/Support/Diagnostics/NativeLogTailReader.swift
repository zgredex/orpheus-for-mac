import Foundation
import NativeQobuzCore

struct NativeLogTailReader {
    private let codec: NativeLogCodec
    private let blockBytes = 64 * 1_024

    init(codec: NativeLogCodec) {
        self.codec = codec
    }

    func loadEntries(
        files: [NativeLogFile],
        directory: NativeLogDirectory,
        limit: Int
    ) throws -> [QobuzLogEntry] {
        let limit = max(limit, 1)
        var entries: [QobuzLogEntry] = []
        var corruptLines = 0

        for file in files.reversed() where entries.count < limit {
            let lines = try tailLines(in: file, directory: directory, limit: limit - entries.count)
            var decoded: [QobuzLogEntry] = []
            for line in lines {
                do { decoded.append(try codec.decodeLine(line)) }
                catch { corruptLines += 1 }
            }
            entries.insert(contentsOf: decoded, at: 0)
        }

        if corruptLines > 0 {
            entries.append(corruptRecord(count: corruptLines))
        }
        return Array(entries.suffix(limit))
    }

    private func tailLines(
        in file: NativeLogFile,
        directory: NativeLogDirectory,
        limit: Int
    ) throws -> [Data] {
        try directory.withReadableHandle(for: file) { handle in
            var position = try handle.seekToEnd()
            var chunks: [Data] = []
            var newlineCount = 0

            while position > 0, newlineCount <= limit {
                let count = min(UInt64(blockBytes), position)
                position -= count
                try handle.seek(toOffset: position)
                let chunk = try handle.read(upToCount: Int(count)) ?? Data()
                newlineCount += chunk.reduce(into: 0) { count, byte in
                    if byte == 0x0A { count += 1 }
                }
                chunks.append(chunk)
            }

            var tail = Data()
            for chunk in chunks.reversed() { tail.append(chunk) }
            let bytes: [UInt8] = Array(tail)
            let byteLines: [ArraySlice<UInt8>] = bytes.split(
                separator: 0x0A,
                omittingEmptySubsequences: true
            )
            var lines = byteLines.map { Data($0) }
            if position > 0, !lines.isEmpty {
                // The oldest bytes start in the middle of a record. Newer complete
                // records remain intact and are the only records requested by a tail read.
                lines.removeFirst()
            }
            return Array(lines.suffix(limit))
        }
    }

    private func corruptRecord(count: Int) -> QobuzLogEntry {
        QobuzLogEntry(
            sessionID: QobuzDiagnostics.shared.sessionID,
            level: .warning,
            category: "diagnostics",
            message: "Some persisted log records could not be decoded",
            metadata: ["corruptLines": String(count)],
            sourceFile: #fileID,
            sourceFunction: #function,
            sourceLine: #line,
            thread: "reader"
        )
    }
}
