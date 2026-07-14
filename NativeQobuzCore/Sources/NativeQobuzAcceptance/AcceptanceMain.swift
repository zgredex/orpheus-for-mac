import Darwin
import Foundation
import NativeQobuzCore

private struct CredentialDocument: Decodable {
    let appID: String
    let appSecret: String
    let authToken: String
}

private struct ResumeRecord: Codable {
    let trackID: String
    let quality: QobuzQuality
    let destinationName: String
}

private struct MediaFixture {
    let album: QobuzAlbum
    let track: QobuzTrack
    let hiResInfo: QobuzFileInfo
}

@main
struct NativeQobuzAcceptance {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        let outputRoot = URL(
            fileURLWithPath: environment["QOBUZ_ACCEPTANCE_OUTPUT"]
                ?? FileManager.default.currentDirectoryPath + "/Build/Acceptance",
            isDirectory: true
        )
        let reportURL = outputRoot.appendingPathComponent("acceptance-report.json")
        let credentialPath = environment["QOBUZ_CREDENTIALS_FILE"] ?? ""
        let matrix: AcceptanceMatrix
        do {
            matrix = try AcceptanceMatrix(destination: reportURL, secrets: [credentialPath, outputRoot.path])
        } catch {
            fputs("Could not create the acceptance report.\n", stderr)
            exit(2)
        }

        guard let document = await matrix.capture(
            "configuration.credentials",
            title: "Load owner-protected credential file"
        , operation: {
            try require(!credentialPath.isEmpty, "QOBUZ_CREDENTIALS_FILE was not provided.")
            let url = URL(fileURLWithPath: credentialPath)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            try require(permissions & 0o077 == 0, "Credential file permissions are not owner-only.")
            return try JSONDecoder().decode(CredentialDocument.self, from: Data(contentsOf: url))
        }) else {
            _ = try? matrix.finish()
            exit(2)
        }

        let credentials = QobuzCredentials(
            appID: document.appID,
            appSecret: document.appSecret,
            authToken: document.authToken
        )
        matrix.addSecrets([document.appID, document.appSecret, document.authToken])
        guard credentials.isComplete else {
            await matrix.check("configuration.complete", title: "Credentials are complete") {
                throw AcceptanceFailure(message: "Credential file contains blank required values.")
            }
            _ = try? matrix.finish()
            exit(2)
        }

        let client = QobuzAPIClient(credentials: credentials)
        let albumID = QobuzID(environment["QOBUZ_TEST_ALBUM_ID"] ?? "je3x92urb9drs")
        let artistID = QobuzID(environment["QOBUZ_TEST_ARTIST_ID"] ?? "22407938")
        let playlistID = QobuzID(environment["QOBUZ_TEST_PLAYLIST_ID"] ?? "52736446")
        let labelID = QobuzID(environment["QOBUZ_TEST_LABEL_ID"] ?? "10278643")
        let expectedRegion = environment["QOBUZ_EXPECTED_REGION"] ?? "FR"
        let searchQuery = environment["QOBUZ_TEST_QUERY"] ?? "Adele"
        let runTransfers = environment["QOBUZ_ACCEPTANCE_DOWNLOADS"] == "1"
        let workRoot = outputRoot.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workRoot) }

        if let region: String = await matrix.capture(
            "account.region",
            title: "French account region",
            operation: {
                let value = try await client.validateAccount()
                try require(
                    value.uppercased() == expectedRegion.uppercased(),
                    "Expected account region \(expectedRegion), received \(value)."
                )
                return value
            }
        ) {
            matrix.setAccountRegion(region)
        }

        let album: QobuzAlbum? = await matrix.capture("catalog.album", title: "Album metadata and availability") {
            let value = try await client.album(id: albumID)
            try require(value.accountAvailabilityIssue == nil, "Album is unavailable in the account region.")
            try require(!value.availableTracks.isEmpty, "Album has no available tracks.")
            return value
        }
        _ = await matrix.capture("catalog.track", title: "Track metadata and availability") {
            guard let source = album?.availableTracks.first else {
                throw AcceptanceFailure(message: "Album scenario did not provide a track fixture.")
            }
            let value = try await client.track(id: source.id)
            try require(value.accountAvailabilityIssue == nil, "Track is unavailable in the account region.")
            return value
        } as QobuzTrack?
        let playlist: QobuzPlaylist? = await matrix.capture("catalog.playlist", title: "Playlist metadata and pagination") {
            let value = try await client.playlist(id: playlistID)
            try require(!value.name.isEmpty, "Playlist name is empty.")
            try require(!value.availableTracks.isEmpty, "Playlist has no available tracks.")
            return value
        }
        _ = await matrix.capture("catalog.artist", title: "Artist catalog and pagination") {
            let value = try await client.artist(id: artistID)
            try require(!value.name.isEmpty, "Artist name is empty.")
            try require(!value.officialAlbums.isEmpty, "Artist has no official available albums.")
            return value
        } as QobuzArtistCatalog?
        _ = await matrix.capture("catalog.label", title: "Label catalog and pagination") {
            let value = try await client.label(id: labelID)
            try require(!value.name.isEmpty, "Label name is empty.")
            try require(!value.availableAlbums.isEmpty, "Label has no available albums.")
            return value
        } as QobuzLabelCatalog?

        for category in QobuzSearchCategory.allCases {
            await matrix.check(
                "search.\(category.rawValue)",
                title: "Region-filtered \(category.rawValue) search"
            ) {
                let result = try await client.search(searchQuery, category: category, limit: 30)
                let count = switch category {
                case .albums: result.albums.count
                case .artists: result.artists.count
                case .playlists: result.playlists.count
                case .tracks: result.tracks.count
                }
                try require(count > 0, "Search returned no \(category.rawValue).")
                try require(result.albums.allSatisfy { $0.accountAvailabilityIssue == nil }, "Search exposed an unavailable album.")
                try require(result.tracks.allSatisfy { $0.accountAvailabilityIssue == nil }, "Search exposed an unavailable track.")
            }
        }

        await matrix.check("catalog.mixed-availability", title: "Mixed-availability album filtering") {
            let value = try await mixedAvailabilityAlbum(client: client, environment: environment)
            try require(!value.availableTracks.isEmpty, "Mixed album has no available tracks.")
            try require(value.unavailableTrackCount > 0, "Fixture is not a mixed-availability album.")
        }

        let mediaFixture: MediaFixture? = await matrix.capture(
            "quality.fixture",
            title: "Account-available native Hi-Res fixture"
        ) {
            try await hiResMediaFixture(client: client, preferredAlbum: album, environment: environment)
        }

        var fileInfo: [QobuzQuality: QobuzFileInfo] = [:]
        if let mediaFixture {
            for quality in QobuzQuality.allCases {
                if let info = await matrix.capture(
                    "quality.\(quality.rawValue).authorization",
                    title: "\(qualityTitle(quality)) signed media authorization"
                , operation: {
                    let value = if quality == .hiRes {
                        mediaFixture.hiResInfo
                    } else {
                        try await client.fileInfo(trackID: mediaFixture.track.id, format: quality.maximumFormat)
                    }
                    try require(value.format == quality.maximumFormat, "Qobuz returned format \(value.formatID), expected \(quality.maximumFormat.formatID).")
                    return value
                }) {
                    fileInfo[quality] = info
                }
            }
        } else {
            for quality in QobuzQuality.allCases {
                matrix.skip(
                    "quality.\(quality.rawValue).authorization",
                    title: "\(qualityTitle(quality)) signed media authorization",
                    reason: "A native Hi-Res fixture was unavailable."
                )
            }
        }

        var transfers: [QobuzQuality: URL] = [:]
        for quality in QobuzQuality.allCases {
            let id = "transfer.\(quality.rawValue)"
            let title = if quality == .mp3 {
                "\(qualityTitle(quality)) cancel, relaunch resume, decode, and checksum"
            } else {
                "\(qualityTitle(quality)) transfer, decode, and checksum"
            }
            guard runTransfers else {
                matrix.skip(id, title: title, reason: "Set QOBUZ_ACCEPTANCE_DOWNLOADS=1 for release qualification.")
                continue
            }
            guard let mediaFixture, let info = fileInfo[quality] else {
                matrix.skip(id, title: title, reason: "Signed media authorization did not pass.")
                continue
            }
            if let url = await matrix.capture(id, title: title, operation: {
                let destination = workRoot
                    .appendingPathComponent("transfers", isDirectory: true)
                    .appendingPathComponent("\(quality.rawValue).\(info.fileExtension)")
                if quality == .mp3 {
                    try await transferWithRelaunchResume(
                        client: client,
                        trackID: mediaFixture.track.id,
                        quality: quality,
                        firstURL: info.url,
                        destination: destination,
                        stateRoot: workRoot
                    )
                } else {
                    try await transfer(source: info.url, destination: destination)
                }
                let validator = try FFmpegMediaValidator.bundled()
                try await validator.validate(destination)
                let checksum = try MusicFileIntegrity.sha256(of: destination)
                try require(checksum.count == 64, "SHA-256 output has an invalid length.")
                let verified = try MusicFileIntegrity.verify(destination, expectedSHA256: checksum)
                try require(verified, "SHA-256 verification failed.")
                return destination
            }) {
                transfers[quality] = url
            }
        }

        if let mediaFixture, let rawMP3 = transfers[.mp3], let info = fileInfo[.mp3] {
            await matrix.check(
                "media.metadata-artwork",
                title: "Native metadata, artwork, decode, and final checksum"
            ) {
                try await qualifyMetadataAndArtwork(
                    album: mediaFixture.album,
                    track: mediaFixture.track,
                    fileInfo: info,
                    source: rawMP3,
                    root: workRoot.appendingPathComponent("library", isDirectory: true)
                )
            }

            await matrix.check("library.duplicate-reuse", title: "Verified duplicate audio reuse") {
                try await qualifyDuplicateReuse(
                    client: client,
                    trackID: mediaFixture.track.id,
                    root: workRoot.appendingPathComponent("library", isDirectory: true)
                )
            }

            if let playlist {
                await matrix.check("library.segregation", title: "Album, track, and playlist Library segregation") {
                    try await qualifyLibrarySegregation(
                        album: mediaFixture.album,
                        track: mediaFixture.track,
                        playlist: playlist,
                        fileInfo: info,
                        root: workRoot.appendingPathComponent("library", isDirectory: true)
                    )
                }
            } else {
                matrix.skip("library.segregation", title: "Album, track, and playlist Library segregation", reason: "Playlist fixture was unavailable.")
            }
        } else {
            for (id, title) in [
                ("media.metadata-artwork", "Native metadata, artwork, decode, and final checksum"),
                ("library.duplicate-reuse", "Verified duplicate audio reuse"),
                ("library.segregation", "Album, track, and playlist Library segregation")
            ] {
                matrix.skip(id, title: title, reason: "The MP3 transfer prerequisite did not pass.")
            }
        }

        let qualified = (try? matrix.finish()) ?? false
        print("Acceptance report: \(reportURL.path)")
        print(qualified ? "Release acceptance passed." : "Release acceptance did not pass.")
        exit(qualified ? 0 : 1)
    }

    private static func mixedAvailabilityAlbum(
        client: QobuzAPIClient,
        environment: [String: String]
    ) async throws -> QobuzAlbum {
        if let explicit = environment["QOBUZ_TEST_MIXED_ALBUM_ID"], !explicit.isEmpty {
            return try await client.album(id: QobuzID(explicit))
        }
        for query in ["Adele", "Various Artists", "Greatest Hits"] {
            let results = try await client.search(query, category: .albums, limit: 20)
            for summary in results.albums.prefix(12) {
                if let album = try? await client.album(id: summary.id),
                   !album.availableTracks.isEmpty,
                   album.unavailableTrackCount > 0 {
                    return album
                }
            }
        }
        throw AcceptanceFailure(
            message: "No mixed-availability album was found. Set QOBUZ_TEST_MIXED_ALBUM_ID to a current French-region fixture."
        )
    }

    private static func hiResMediaFixture(
        client: QobuzAPIClient,
        preferredAlbum: QobuzAlbum?,
        environment: [String: String]
    ) async throws -> MediaFixture {
        if let explicit = environment["QOBUZ_TEST_HIRES_TRACK_ID"], !explicit.isEmpty {
            let track = try await client.track(id: QobuzID(explicit))
            guard let albumID = track.album?.id else {
                throw AcceptanceFailure(message: "Explicit Hi-Res track has no album metadata.")
            }
            let album = try await client.album(id: albumID)
            let info = try await client.fileInfo(trackID: track.id, format: QobuzQuality.hiRes.maximumFormat)
            try require(info.format == QobuzQuality.hiRes.maximumFormat, "Explicit fixture is not native Hi-Res.")
            return MediaFixture(album: album, track: track, hiResInfo: info)
        }

        var candidates: [QobuzAlbum] = []
        if let preferredAlbum { candidates.append(preferredAlbum) }
        for query in ["Adele", "Sienna Spiro", "Daft Punk"] {
            let results = try await client.search(query, category: .albums, limit: 30)
            for summary in results.albums where summary.hiresStreamable || (summary.maximumBitDepth ?? 0) > 16 {
                guard !candidates.contains(where: { $0.id == summary.id }),
                      let album = try? await client.album(id: summary.id) else { continue }
                candidates.append(album)
                if candidates.count >= 12 { break }
            }
            if candidates.count >= 12 { break }
        }

        for album in candidates where album.accountAvailabilityIssue == nil {
            for track in album.availableTracks.prefix(4) {
                guard let info = try? await client.fileInfo(trackID: track.id, format: QobuzQuality.hiRes.maximumFormat),
                      info.format == QobuzQuality.hiRes.maximumFormat else { continue }
                return MediaFixture(album: album, track: track, hiResInfo: info)
            }
        }
        throw AcceptanceFailure(message: "No native Hi-Res track was available to the French account.")
    }

    private static func transfer(source: URL, destination: URL) async throws {
        var completed = false
        for try await event in URLSessionFileTransferClient().events(from: source, to: destination) {
            if case .completed(let url) = event { completed = url == destination }
        }
        try require(completed, "Transfer ended without installing the destination file.")
        let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        try require(size > 128 * 1_024, "Transferred audio is suspiciously small.")
    }

    private static func transferWithRelaunchResume(
        client: QobuzAPIClient,
        trackID: QobuzID,
        quality: QobuzQuality,
        firstURL: URL,
        destination: URL,
        stateRoot: URL
    ) async throws {
        try await stopTransferAfterFirstProgress(source: firstURL, destination: destination)
        try await Task.sleep(for: .milliseconds(250))
        let partial = destination.appendingPathExtension("partial")
        let partialSize = (try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
        try require(partialSize > 0, "Cancellation did not preserve a partial audio file.")

        let stateURL = stateRoot.appendingPathComponent("resume-state.json")
        let state = ResumeRecord(trackID: trackID.rawValue, quality: quality, destinationName: destination.lastPathComponent)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        let restored = try JSONDecoder().decode(ResumeRecord.self, from: Data(contentsOf: stateURL))
        try require(restored.trackID == trackID.rawValue && restored.quality == quality, "Relaunch state did not round-trip.")

        let fresh = try await client.fileInfo(trackID: QobuzID(restored.trackID), format: restored.quality.maximumFormat)
        try await transfer(source: fresh.url, destination: destination)
        try require(!FileManager.default.fileExists(atPath: partial.path), "Partial file remained after resume completion.")
        let finalSize = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        try require(finalSize > partialSize, "Resumed transfer did not append and complete safely.")
    }

    private static func stopTransferAfterFirstProgress(source: URL, destination: URL) async throws {
        for try await event in URLSessionFileTransferClient().events(from: source, to: destination) {
            if case .progress(let progress) = event, progress.bytesWritten >= 32 * 1_024 {
                return
            }
        }
        throw AcceptanceFailure(message: "Transfer completed before cancellation could be exercised.")
    }

    private static func qualifyMetadataAndArtwork(
        album: QobuzAlbum,
        track: QobuzTrack,
        fileInfo: QobuzFileInfo,
        source: URL,
        root: URL
    ) async throws {
        let item = QobuzResolvedTrack(
            track: track,
            album: album,
            collection: .track,
            position: 1,
            total: 1
        )
        let destination = StandardQobuzOutputPlanner().destination(for: item, fileInfo: fileInfo, root: root)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        let assets = QobuzCollectionAssetWriter()
        guard let artwork = try await assets.artwork(for: album) else {
            throw AcceptanceFailure(message: "Album did not provide downloadable artwork.")
        }
        try NativeAudioMetadataWriter().write(metadata: QobuzAudioMetadata(item: item), artwork: artwork, to: destination)
        try await FFmpegMediaValidator.bundled().validate(destination)
        let checksum = try MusicFileIntegrity.sha256(of: destination)
        let verified = try MusicFileIntegrity.verify(destination, expectedSHA256: checksum)
        try require(verified, "Tagged file checksum failed.")
        try assets.recordProvenance(QobuzFileProvenance(item: item, fileInfo: fileInfo, sha256: checksum), for: destination)
        _ = try assets.writeChecksumManifests(for: [(item, destination, checksum)])
        let cover = try assets.saveExternalArtwork(artwork, for: item, audioURL: destination)
        try require(cover.map { FileManager.default.fileExists(atPath: $0.path) } == true, "External cover artwork was not written.")
        let expectedChecksum = try assets.expectedChecksum(for: destination)
        try require(expectedChecksum == checksum, "Checksum manifest does not match the tagged file.")
    }

    private static func qualifyDuplicateReuse(client: QobuzAPIClient, trackID: QobuzID, root: URL) async throws {
        let engine = NativeQobuzDownloadEngine(
            service: client,
            validator: try FFmpegMediaValidator.bundled()
        )
        var skipped = false
        var downloaded = false
        for try await event in engine.events(for: .track(trackID), quality: .mp3, downloadRoot: root) {
            switch event {
            case .trackSkipped: skipped = true
            case .trackCompleted: downloaded = true
            default: break
            }
        }
        try require(skipped, "Engine did not reuse the verified existing audio.")
        try require(!downloaded, "Engine downloaded a duplicate physical file.")
    }

    private static func qualifyLibrarySegregation(
        album: QobuzAlbum,
        track: QobuzTrack,
        playlist: QobuzPlaylist,
        fileInfo: QobuzFileInfo,
        root: URL
    ) async throws {
        let item = QobuzResolvedTrack(track: track, album: album, collection: .track, position: 1, total: 1)
        let audio = StandardQobuzOutputPlanner().destination(for: item, fileInfo: fileInfo, root: root)
        try require(FileManager.default.fileExists(atPath: audio.path), "Qualified audio file is missing.")
        let outputs = [(item: item, audioURL: audio)]
        let writer = QobuzCollectionAssetWriter()
        _ = try writer.recordLibraryCollections(
            plan: QobuzDownloadPlan(request: .track(track.id), title: track.displayTitle, tracks: [item], source: .track(track)),
            outputs: outputs,
            downloadRoot: root
        )
        _ = try writer.recordLibraryCollections(
            plan: QobuzDownloadPlan(request: .album(album.id), title: album.displayTitle, tracks: [item], source: .album(album)),
            outputs: outputs,
            downloadRoot: root
        )
        _ = try writer.recordLibraryCollections(
            plan: QobuzDownloadPlan(request: .playlist(playlist.id), title: playlist.name, tracks: [item], source: .playlist(playlist)),
            outputs: outputs,
            downloadRoot: root
        )
        try writer.markLibraryManaged([audio])
        let snapshot = try await QobuzArchiveScanner().scan(root: root)
        try require(snapshot.tracks.count == 1, "Library created duplicate physical track records.")
        try require(snapshot.albumCount == 1, "Album entry was not segregated.")
        try require(snapshot.standaloneTrackCount == 1, "Standalone track entry was not segregated.")
        try require(snapshot.playlistCount == 1, "Playlist entry was not segregated.")
        try require(snapshot.unclassifiedCount == 0, "Managed audio leaked into unclassified downloads.")
        try require(snapshot.problemCount == 0, "Library verification reported an integrity problem.")
    }

    private static func qualityTitle(_ quality: QobuzQuality) -> String {
        switch quality {
        case .mp3: "MP3 320 kbps"
        case .lossless: "Lossless FLAC"
        case .hiRes: "Hi-Res FLAC"
        }
    }
}
