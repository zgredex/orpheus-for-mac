import CryptoKit
import Foundation

protocol AudioMetadataFileRewriter: Sendable {
    @discardableResult
    func rewrite(
        metadata: QobuzAudioMetadata,
        artwork: EmbeddedArtwork?,
        path: LibraryRelativePath,
        input: FileHandle,
        fileSystem: LibraryFileSystem
    ) throws -> String
}

extension AudioMetadataFileRewriter {
    @discardableResult
    func write(
        metadata: QobuzAudioMetadata,
        artwork: EmbeddedArtwork?,
        to path: LibraryRelativePath,
        fileSystem: LibraryFileSystem
    ) throws -> String {
        try fileSystem.withReadableHandle(at: path) {
            try rewrite(metadata: metadata, artwork: artwork, path: path, input: $0, fileSystem: fileSystem)
        }
    }
}

struct ID3v23Writer: AudioMetadataFileRewriter {
    func rewrite(
        metadata: QobuzAudioMetadata,
        artwork: EmbeddedArtwork?,
        path: LibraryRelativePath,
        input: FileHandle,
        fileSystem: LibraryFileSystem
    ) throws -> String {
        let prefix = try input.read(upToCount: 10) ?? Data()
        let audioOffset: UInt64
        if prefix.count == 10, prefix.starts(with: Data("ID3".utf8)) {
            let size = decodeSynchsafe(prefix[6..<10])
            audioOffset = UInt64(10 + size + ((prefix[5] & 0x10) == 0x10 ? 10 : 0))
        } else {
            audioOffset = 0
        }

        var frames = Data()
        addTextFrame("TIT2", metadata.title, to: &frames)
        addTextFrame("TALB", metadata.album, to: &frames)
        // ID3v2.3 readers commonly stop at NUL, so use the same portable
        // delimiter policy as TPE2 rather than the ID3v2.4 multi-value form.
        addTextFrame("TPE1", metadata.artists.joined(separator: "; "), to: &frames)
        // ID3v2.3 has one TPE2 text value. A semicolon keeps multiple album
        // artists readable without using the ambiguous v2.3 slash convention.
        addTextFrame("TPE2", metadata.albumArtists.joined(separator: "; "), to: &frames)
        addTextFrame("TCOM", metadata.composer, to: &frames)
        addTextFrame("TYER", metadata.releaseDate.map { String($0.prefix(4)) }, to: &frames)
        if let date = metadata.releaseDate, date.count >= 10 {
            let monthStart = date.index(date.startIndex, offsetBy: 5)
            let dayStart = date.index(date.startIndex, offsetBy: 8)
            addTextFrame("TDAT", "\(date[dayStart...].prefix(2))\(date[monthStart...].prefix(2))", to: &frames)
        }
        addTextFrame("TRCK", numbered(metadata.trackNumber, total: metadata.totalTracks), to: &frames)
        addTextFrame("TPOS", numbered(metadata.discNumber, total: metadata.totalDiscs), to: &frames)
        addTextFrame("TSRC", metadata.isrc, to: &frames)
        addTextFrame("TPUB", metadata.label, to: &frames)
        addTextFrame("TCOP", metadata.copyright, to: &frames)
        addTextFrame("TCON", metadata.genre, to: &frames)
        addUserTextFrame(description: "BARCODE", value: metadata.barcode, to: &frames)
        addUserTextFrame(description: "Rating", value: metadata.isExplicit ? "Explicit" : "Clean", to: &frames)
        for role in metadata.credits.keys.sorted() {
            addUserTextFrame(description: role, values: metadata.credits[role] ?? [], to: &frames)
        }
        if let artwork { addArtworkFrame(artwork, to: &frames) }

        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [3, 0, 0])
        tag.append(contentsOf: encodeSynchsafe(frames.count))
        tag.append(frames)

        return try AtomicFileEditor.rewrite(path, fileSystem: fileSystem) { output in
            try output.write(contentsOf: tag)
            try input.seek(toOffset: audioOffset)
            try AtomicFileEditor.copy(input, to: output)
        }
    }

    private func addTextFrame(_ id: String, _ value: String?, to frames: inout Data) {
        guard let value, !value.isEmpty else { return }
        var payload = Data([1])
        payload.append(utf16(value))
        addFrame(id, payload: payload, to: &frames)
    }

    private func addUserTextFrame(description: String, value: String?, to frames: inout Data) {
        guard let value, !value.isEmpty else { return }
        addUserTextFrame(description: description, values: [value], to: &frames)
    }

    private func addUserTextFrame(description: String, values: [String], to frames: inout Data) {
        guard !values.isEmpty else { return }
        var payload = Data([1])
        payload.append(utf16(description))
        payload.append(contentsOf: [0, 0])
        payload.append(utf16(values.joined(separator: "\u{0000}")))
        addFrame("TXXX", payload: payload, to: &frames)
    }

    private func addArtworkFrame(_ artwork: EmbeddedArtwork, to frames: inout Data) {
        var payload = Data([3])
        payload.append(Data(artwork.mimeType.utf8))
        payload.append(contentsOf: [0, 3])
        payload.append(Data("Cover".utf8))
        payload.append(0)
        payload.append(artwork.data)
        addFrame("APIC", payload: payload, to: &frames)
    }

    private func addFrame(_ id: String, payload: Data, to frames: inout Data) {
        frames.append(Data(id.utf8))
        frames.append(contentsOf: encodeBigEndian(payload.count))
        frames.append(contentsOf: [0, 0])
        frames.append(payload)
    }

    private func numbered(_ value: Int?, total: Int?) -> String? {
        guard let value else { return nil }
        guard let total, total > 0 else { return String(value) }
        return "\(value)/\(total)"
    }

    private func encodeSynchsafe(_ value: Int) -> [UInt8] {
        [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
    }

    private func encodeBigEndian(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private func utf16(_ value: String) -> Data {
        var result = Data([0xFF, 0xFE])
        for unit in value.utf16 {
            result.append(UInt8(unit & 0xFF))
            result.append(UInt8((unit >> 8) & 0xFF))
        }
        return result
    }

    private func decodeSynchsafe(_ bytes: Data.SubSequence) -> Int {
        bytes.reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
    }
}

struct FLACMetadataWriter: AudioMetadataFileRewriter {
    private struct Block {
        let type: UInt8
        let data: Data
    }

    func rewrite(
        metadata: QobuzAudioMetadata,
        artwork: EmbeddedArtwork?,
        path: LibraryRelativePath,
        input: FileHandle,
        fileSystem: LibraryFileSystem
    ) throws -> String {
        guard try input.read(upToCount: 4) == Data("fLaC".utf8) else {
            throw NativeQobuzError.fileSystem("Invalid FLAC signature in \(path.lastComponent ?? path.rawValue)")
        }

        var retained: [Block] = []
        var isLast = false
        while !isLast {
            let header = try readExactly(4, from: input)
            isLast = (header[0] & 0x80) != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            let payload = try readExactly(length, from: input)
            if type != 4 && type != 6 { retained.append(Block(type: type, data: payload)) }
        }
        let audioOffset = try input.offset()

        var blocks = retained
        blocks.append(Block(type: 4, data: vorbisComment(metadata)))
        if let artwork { blocks.append(Block(type: 6, data: picture(artwork))) }

        return try AtomicFileEditor.rewrite(path, fileSystem: fileSystem) { output in
            try output.write(contentsOf: Data("fLaC".utf8))
            for (index, block) in blocks.enumerated() {
                guard block.data.count <= 0xFF_FFFF else {
                    throw NativeQobuzError.fileSystem("FLAC metadata block is too large")
                }
                let lastFlag: UInt8 = index == blocks.count - 1 ? 0x80 : 0
                let length = block.data.count
                try output.write(contentsOf: Data([
                    lastFlag | block.type,
                    UInt8((length >> 16) & 0xFF),
                    UInt8((length >> 8) & 0xFF),
                    UInt8(length & 0xFF)
                ]))
                try output.write(contentsOf: block.data)
            }
            try input.seek(toOffset: audioOffset)
            try AtomicFileEditor.copy(input, to: output)
        }
    }

    private func vorbisComment(_ metadata: QobuzAudioMetadata) -> Data {
        var comments: [String] = []
        append("TITLE", metadata.title, to: &comments)
        append("ALBUM", metadata.album, to: &comments)
        metadata.artists.forEach { append("ARTIST", $0, to: &comments) }
        metadata.albumArtists.forEach { append("ALBUMARTIST", $0, to: &comments) }
        append("COMPOSER", metadata.composer, to: &comments)
        append("DATE", metadata.releaseDate, to: &comments)
        append("TRACKNUMBER", metadata.trackNumber.map(String.init), to: &comments)
        append("TOTALTRACKS", metadata.totalTracks.map(String.init), to: &comments)
        append("DISCNUMBER", metadata.discNumber.map(String.init), to: &comments)
        append("TOTALDISCS", metadata.totalDiscs.map(String.init), to: &comments)
        append("ISRC", metadata.isrc, to: &comments)
        append("UPC", metadata.barcode, to: &comments)
        append("LABEL", metadata.label, to: &comments)
        append("COPYRIGHT", metadata.copyright, to: &comments)
        append("GENRE", metadata.genre, to: &comments)
        append("RATING", metadata.isExplicit ? "Explicit" : "Clean", to: &comments)
        for role in metadata.credits.keys.sorted() {
            for name in metadata.credits[role] ?? [] { append(role, name, to: &comments) }
        }

        var result = Data()
        result.appendLittleEndian(Data("Orpheus for Mac".utf8))
        result.appendLittleEndian(UInt32(comments.count))
        for comment in comments { result.appendLittleEndian(Data(comment.utf8)) }
        return result
    }

    private func picture(_ artwork: EmbeddedArtwork) -> Data {
        var result = Data()
        result.appendBigEndian(UInt32(3))
        result.appendBigEndian(Data(artwork.mimeType.utf8))
        result.appendBigEndian(Data())
        result.appendBigEndian(UInt32(clamping: artwork.width))
        result.appendBigEndian(UInt32(clamping: artwork.height))
        result.appendBigEndian(UInt32(clamping: artwork.depth))
        result.appendBigEndian(UInt32(0))
        result.appendBigEndian(artwork.data)
        return result
    }

    private func append(_ key: String, _ value: String?, to comments: inout [String]) {
        guard let value, !value.isEmpty else { return }
        comments.append("\(key)=\(value)")
    }

    private func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        guard count >= 0, let data = try handle.read(upToCount: count), data.count == count else {
            throw NativeQobuzError.fileSystem("Unexpected end of FLAC metadata")
        }
        return data
    }
}

private enum AtomicFileEditor {
    @discardableResult
    static func rewrite(
        _ destination: LibraryRelativePath,
        fileSystem: LibraryFileSystem,
        body: (HashingFileWriter) throws -> Void
    ) throws -> String {
        let temporaryName = QobuzFilenameComponent.make(
            prefix: ".",
            stem: destination.lastComponent ?? "audio",
            suffix: ".metadata-\(UUID().uuidString)"
        )
        let temporary = try destination.parent.appending(temporaryName)
        do {
            let output = try fileSystem.writableHandle(at: temporary, truncate: true)
            do {
                let writer = HashingFileWriter(handle: output)
                try body(writer)
                let checksum = writer.finalize()
                try output.synchronize()
                try output.close()
                try fileSystem.replaceItem(at: destination, with: temporary)
                return checksum
            } catch {
                try? output.close()
                throw error
            }
        } catch {
            try? fileSystem.removeFile(temporary, ifPresent: true)
            throw error
        }
    }

    static func copy(_ input: FileHandle, to output: HashingFileWriter) throws {
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }
}

private final class HashingFileWriter {
    private let handle: FileHandle
    private var digest = SHA256()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(contentsOf data: Data) throws {
        try handle.write(contentsOf: data)
        digest.update(data: data)
    }

    func finalize() -> String {
        digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)
        ])
    }

    mutating func appendLittleEndian(_ data: Data) {
        appendLittleEndian(UInt32(clamping: data.count))
        append(data)
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)
        ])
    }

    mutating func appendBigEndian(_ data: Data) {
        appendBigEndian(UInt32(clamping: data.count))
        append(data)
    }
}
