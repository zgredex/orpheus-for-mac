import XCTest
@testable import NativeQobuzCore

final class LibraryFinalizationTransactionTests: XCTestCase {
    func testFailureAfterEveryManifestOrProvenanceMutationRollsBackAllOwnership() async throws {
        for failingIndex in 0...2 {
            let fixture = try LibraryFinalizationFixture(kind: .artist)
            defer { fixture.cleanup() }
            let transaction = fixture.transaction { checkpoint in
                if case .appliedMutation(let index) = checkpoint, index == failingIndex {
                    throw InjectedLibraryFinalizationFailure.stop
                }
            }

            do {
                _ = try await transaction.commit(
                    plan: fixture.plan,
                    outputs: fixture.outputs,
                    fileSystem: fixture.fileSystem
                )
                XCTFail("Expected mutation \(failingIndex) to fail")
            } catch InjectedLibraryFinalizationFailure.stop {
            }

            XCTAssertNil(try fixture.fileSystem.metadata(at: fixture.manifestPath))
            XCTAssertEqual(try fixture.managedFlags(), [false, false])
            XCTAssertTrue(try fixture.transactionDirectories().isEmpty)
            try fixture.assertAudioUnchanged()
        }
    }

    func testPlaylistAndManifestRollBackTogetherWhenM3UWasAlreadyWritten() async throws {
        let fixture = try LibraryFinalizationFixture(kind: .playlist)
        defer { fixture.cleanup() }
        let transaction = fixture.transaction { checkpoint in
            if case .appliedMutation(let index) = checkpoint, index == 1 {
                throw InjectedLibraryFinalizationFailure.stop
            }
        }

        do {
            _ = try await transaction.commit(
                plan: fixture.plan,
                outputs: fixture.outputs,
                fileSystem: fixture.fileSystem
            )
            XCTFail("Expected playlist mutation to fail")
        } catch InjectedLibraryFinalizationFailure.stop {
        }

        XCTAssertNil(try fixture.fileSystem.metadata(at: fixture.manifestPath))
        XCTAssertNil(try fixture.fileSystem.metadata(at: try fixture.playlistPath()))
        XCTAssertEqual(try fixture.managedFlags(), [false])
        XCTAssertTrue(try fixture.transactionDirectories().isEmpty)
    }

    func testSuccessfulFinalizationPublishesManifestAndManagedProvenanceTogether() async throws {
        let fixture = try LibraryFinalizationFixture(kind: .artist)
        defer { fixture.cleanup() }

        let assets = try await fixture.transaction().commit(
            plan: fixture.plan,
            outputs: fixture.outputs,
            fileSystem: fixture.fileSystem
        )

        XCTAssertEqual(assets.manifestURL, fixture.fileSystem.displayURL(for: fixture.manifestPath))
        XCTAssertEqual(try QobuzLibraryManifestIO.load(in: fixture.fileSystem).collections.count, 2)
        XCTAssertEqual(try fixture.managedFlags(), [true, true])
        XCTAssertTrue(try fixture.transactionDirectories().isEmpty)
    }
}

private enum InjectedLibraryFinalizationFailure: Error {
    case stop
}

private struct LibraryFinalizationFixture {
    enum Kind: Equatable { case artist, playlist }

    let root: URL
    let fileSystem: LibraryFileSystem
    let plan: QobuzDownloadPlan
    let outputs: [(item: QobuzResolvedTrack, audioURL: URL)]
    let manifestPath: LibraryRelativePath
    private let provenanceStore = QobuzProvenanceStore()
    private let folderPlanner: QobuzPlaylistFolderPlanner

    init(kind: Kind) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryFinalization-\(UUID().uuidString)", isDirectory: true)
        fileSystem = try LibraryFileSystem(rootURL: root)
        manifestPath = try LibraryRelativePath(QobuzLibraryManifestIO.filename)
        folderPlanner = QobuzPlaylistFolderPlanner(outputPlanner: StandardQobuzOutputPlanner())

        let collection: QobuzCollection
        let request: QobuzRequest
        let identifiers: [(track: String, album: String, folder: String)]
        switch kind {
        case .artist:
            collection = .artist(id: QobuzID("artist"), name: "Artist")
            request = .artist(QobuzID("artist"))
            identifiers = [("a", "album-a", "A"), ("b", "album-b", "B")]
        case .playlist:
            collection = .playlist(id: QobuzID("playlist"), title: "Mix")
            request = .playlist(QobuzID("playlist"))
            identifiers = [("a", "album-a", "A")]
        }

        var resolved: [QobuzResolvedTrack] = []
        var seeded: [(item: QobuzResolvedTrack, audioURL: URL)] = []
        for (offset, identity) in identifiers.enumerated() {
            let artist = QobuzArtist(id: QobuzID("artist-\(identity.track)"), name: "Artist")
            let albumSummary = QobuzAlbumSummary(
                id: QobuzID(identity.album),
                title: "Album \(identity.track.uppercased())",
                artist: artist
            )
            let track = QobuzTrack(
                id: QobuzID(identity.track),
                title: identity.track.uppercased(),
                performer: artist,
                album: albumSummary,
                trackNumber: 1,
                mediaNumber: 1
            )
            let album = QobuzAlbum(
                id: albumSummary.id,
                title: albumSummary.title,
                artist: artist,
                tracks: [track],
                tracksCount: 1,
                mediaCount: 1
            )
            let item = QobuzResolvedTrack(
                track: track,
                album: album,
                collection: collection,
                position: offset + 1,
                total: identifiers.count
            )
            let path = try LibraryRelativePath(
                "Artist \(identity.folder)/Album \(identity.folder)/\(identity.track).flac"
            )
            let data = Data("audio-\(identity.track)".utf8)
            try fileSystem.writeAtomically(data, to: path)
            let audioURL = fileSystem.displayURL(for: path)
            let info = QobuzFileInfo(
                url: URL(string: "https://media.example/\(identity.track).flac")!,
                format: .lossless,
                bitDepth: 16,
                samplingRate: 44.1
            )
            try provenanceStore.record(
                QobuzFileProvenance(
                    item: item,
                    delivery: try validatedTestDelivery(for: info),
                    sha256: try MusicFileIntegrity.sha256(of: path, in: fileSystem)
                ),
                for: audioURL,
                fileSystem: fileSystem
            )
            resolved.append(item)
            seeded.append((item, audioURL))
        }
        outputs = seeded
        let source: QobuzDownloadSource? = switch kind {
        case .artist: nil
        case .playlist:
            .playlist(QobuzPlaylist(
                id: QobuzID("playlist"),
                name: "Mix",
                tracks: resolved.map(\.track),
                tracksCount: resolved.count
            ))
        }
        plan = QobuzDownloadPlan(
            request: request,
            title: kind == .playlist ? "Mix" : "Artist",
            tracks: resolved,
            source: source
        )
    }

    func transaction(
        faultInjector: @escaping LibraryFileTransaction.FaultInjector = { _ in }
    ) -> QobuzLibraryFinalizationTransaction {
        let playlistAssets = QobuzPlaylistAssets(
            fetcher: RejectingFinalizationAssetFetcher(),
            outputPlanner: StandardQobuzOutputPlanner(),
            folderPlanner: folderPlanner
        )
        return QobuzLibraryFinalizationTransaction(
            libraryWriter: QobuzLibraryCollectionWriter(folderPlanner: folderPlanner),
            playlistAssets: playlistAssets,
            provenanceStore: provenanceStore,
            faultInjector: faultInjector
        )
    }

    func managedFlags() throws -> [Bool] {
        try outputs.map {
            try provenanceStore.provenance(for: $0.audioURL, fileSystem: fileSystem)?.isLibraryManaged
                ?? false
        }
    }

    func playlistPath() throws -> LibraryRelativePath {
        try fileSystem.relativePath(
            for: folderPlanner.folder(title: "Mix", id: QobuzID("playlist"), root: root)
        ).appending("Mix.m3u")
    }

    func transactionDirectories() throws -> [LibraryDirectoryEntry] {
        try fileSystem.entries(in: .root).filter {
            $0.path.lastComponent?.hasPrefix(LibraryFileTransactionJournal.directoryPrefix) == true
        }
    }

    func assertAudioUnchanged(file: StaticString = #filePath, line: UInt = #line) throws {
        for output in outputs {
            let expected = Data("audio-\(output.item.track.id.rawValue)".utf8)
            XCTAssertEqual(try Data(contentsOf: output.audioURL), expected, file: file, line: line)
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct RejectingFinalizationAssetFetcher: QobuzAssetFetching {
    func fetch(_ url: URL, maximumBytes: Int) async throws -> QobuzAssetResponse {
        throw NativeQobuzError.unavailable("Unexpected asset request: \(url)")
    }
}
