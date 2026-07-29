import Foundation
import XCTest
@testable import NativeQobuzCore

final class ArchiveIndexTests: XCTestCase {
    func testScannerIndexesExactIDsAndIntegrityWithoutFilenameInference() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
        try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
        let verifiedURL = albumFolder.appendingPathComponent("01. Completely Arbitrary Name.flac")
        let changedURL = albumFolder.appendingPathComponent("02. Changed.flac")
        try Data("verified".utf8).write(to: verifiedURL)
        try Data("changed".utf8).write(to: changedURL)
        let verifiedHash = try MusicFileIntegrity.sha256(of: verifiedURL)
        let originalChangedHash = try MusicFileIntegrity.sha256(of: changedURL)
        let manifest = TestManifest(files: [
            verifiedURL.lastPathComponent: provenance(
                trackID: "track-exact",
                albumID: "album-exact",
                hash: verifiedHash
            ),
            changedURL.lastPathComponent: provenance(
                trackID: "track-changed",
                albumID: "album-exact",
                hash: String(repeating: "0", count: 64)
            ),
            "03. Missing.flac": provenance(
                trackID: "track-missing",
                albumID: "album-exact",
                hash: String(repeating: "1", count: 64)
            )
        ])
        try JSONEncoder().encode(manifest).write(
            to: albumFolder.appendingPathComponent(".orpheus-provenance.json")
        )
        try Data("""
        \(verifiedHash)  \(verifiedURL.lastPathComponent)
        \(originalChangedHash)  \(changedURL.lastPathComponent)
        """.utf8).write(to: albumFolder.appendingPathComponent("checksums.sha256"))

        let snapshot = try await QobuzArchiveScanner().scan(root: root)

        XCTAssertEqual(snapshot.albumCount, 1)
        XCTAssertEqual(snapshot.tracks.count, 3)
        XCTAssertEqual(snapshot.verifiedCount, 1)
        XCTAssertEqual(snapshot.tracks.first { $0.qobuzTrackID == "track-exact" }?.integrity, .verified)
        XCTAssertEqual(snapshot.tracks.first { $0.qobuzTrackID == "track-changed" }?.integrity, .metadataConflict)
        XCTAssertEqual(snapshot.tracks.first { $0.qobuzTrackID == "track-missing" }?.integrity, .missing)
        XCTAssertEqual(
            snapshot.tracks.first { $0.qobuzTrackID == "track-exact" }?.relativePath,
            "Artist/Album/01. Completely Arbitrary Name.flac"
        )
    }

    func testScannerReportsMalformedManifestsAndUnsafeFilenames() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: first.appendingPathComponent(".orpheus-provenance.json"))
        let unsafe = TestManifest(files: [
            "../outside.flac": provenance(
                trackID: "outside",
                albumID: "outside",
                hash: String(repeating: "0", count: 64)
            )
        ])
        try JSONEncoder().encode(unsafe).write(to: second.appendingPathComponent(".orpheus-provenance.json"))

        let snapshot = try await QobuzArchiveScanner().scan(root: root)

        XCTAssertTrue(snapshot.tracks.isEmpty)
        XCTAssertEqual(snapshot.issues.count, 2)
        XCTAssertTrue(snapshot.issues.contains { $0.message.contains("unsafe") })
    }

    func testMissingRootReturnsAnEmptyDiagnosticSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let snapshot = try await QobuzArchiveScanner().scan(root: root)

        XCTAssertTrue(snapshot.tracks.isEmpty)
        XCTAssertEqual(snapshot.issues.first?.message, "Download folder does not exist yet.")
    }

    func testCoverageUsesExactTrackAndAlbumIDs() {
        let snapshot = QobuzArchiveSnapshot(rootPath: "/Music", tracks: [
            archiveTrack(trackID: "one", albumID: "album-a", integrity: .verified),
            archiveTrack(trackID: "two", albumID: "album-a", integrity: .checksumMismatch),
            archiveTrack(trackID: "one", albumID: "album-b", integrity: .verified)
        ])

        let album = snapshot.coverage(
            trackIDs: [QobuzID("one"), QobuzID("two"), QobuzID("missing")],
            albumID: QobuzID("album-a")
        )
        XCTAssertEqual(album.matchedCount, 2)
        XCTAssertEqual(album.verifiedCount, 1)
        XCTAssertEqual(album.problemCount, 1)
        XCTAssertEqual(album.expectedCount, 3)
        XCTAssertFalse(album.isComplete)

        let wrongAlbum = snapshot.coverage(
            trackID: QobuzID("one"),
            albumID: QobuzID("not-this-album")
        )
        XCTAssertEqual(wrongAlbum.matchedCount, 0)
    }

    func testCoverageOnlyClaimsCompleteWhenEveryExpectedTrackIsClean() {
        let clean = archiveTrack(trackID: "one", albumID: "album", integrity: .verified)
        let duplicateProblem = archiveTrack(
            relativePath: "duplicate.flac",
            trackID: "one",
            albumID: "album",
            integrity: .checksumMismatch
        )
        let snapshot = QobuzArchiveSnapshot(rootPath: "/Music", tracks: [clean, duplicateProblem])

        let coverage = snapshot.coverage(trackID: QobuzID("one"), albumID: QobuzID("album"))
        XCTAssertEqual(coverage.verifiedCount, 1)
        XCTAssertEqual(coverage.problemCount, 1)
        XCTAssertFalse(coverage.isComplete)
    }

    func testProblemCountDoesNotDoubleCountATrackDiagnostic() {
        let unreadable = archiveTrack(
            relativePath: "Album/unreadable.flac",
            trackID: "one",
            albumID: "album",
            integrity: .unreadable
        )
        let snapshot = QobuzArchiveSnapshot(
            rootPath: "/Music",
            tracks: [unreadable],
            issues: [
                QobuzArchiveIssue(relativePath: unreadable.relativePath, message: "Permission denied"),
                QobuzArchiveIssue(relativePath: "Broken/.orpheus-provenance.json", message: "Malformed")
            ]
        )

        XCTAssertEqual(snapshot.problemCount, 2)
    }

    func testLibraryProjectionPartitionsEveryFileIntoExactlyOneSection() {
        let tracks = [
            archiveTrack(
                relativePath: "Adele/19/01. Daydreamer.flac",
                trackID: "album-one",
                albumID: "19",
                integrity: .verified,
                archiveKind: .album
            ),
            archiveTrack(
                relativePath: "Adele/19/02. Best for Last.flac",
                trackID: "album-two",
                albumID: "19",
                integrity: .verified,
                archiveKind: .album
            ),
            archiveTrack(
                relativePath: "Adele/Hello.flac",
                trackID: "single",
                albumID: "25",
                integrity: .verified,
                archiveKind: .track
            ),
            archiveTrack(
                relativePath: "Sunday Mix/01. Adele - Easy on Me.flac",
                trackID: "playlist-one",
                albumID: "30",
                integrity: .verified,
                archiveKind: .playlist
            ),
            archiveTrack(
                relativePath: "Imported/Unknown.flac",
                trackID: "older",
                albumID: "old",
                integrity: .verified,
                archiveKind: .unclassified
            )
        ]

        let library = QobuzArchiveLibrary(tracks: tracks)

        XCTAssertEqual(library.count(of: .album), 1)
        XCTAssertEqual(library.count(of: .track), 1)
        XCTAssertEqual(library.count(of: .playlist), 1)
        XCTAssertEqual(library.count(of: .unclassified), 1)
        XCTAssertEqual(library.entries(of: .album).first?.tracks.count, 2)
        XCTAssertEqual(library.entries(of: .album).first?.title, "19")
        XCTAssertEqual(library.entries(of: .track).first?.title, "Hello")

        let projectedPaths = library.entries.flatMap(\.tracks).map(\.relativePath)
        XCTAssertEqual(projectedPaths.count, tracks.count)
        XCTAssertEqual(Set(projectedPaths), Set(tracks.map(\.relativePath)))
    }

    func testLogicalCollectionsCanShareOnePhysicalTrackWithoutDuplicatingBytes() {
        let track = archiveTrack(
            relativePath: "Artist/Album/01. Song.flac",
            trackID: "song",
            albumID: "album",
            integrity: .verified,
            archiveKind: .album
        )
        let sharedPath = track.relativePath
        let collections = [
            QobuzLibraryCollectionRecord(
                id: "album|album",
                kind: .album,
                qobuzID: "album",
                title: "Album",
                subtitle: "Artist · 1 track",
                relativePath: "Artist/Album",
                trackPaths: [sharedPath]
            ),
            QobuzLibraryCollectionRecord(
                id: "track|song",
                kind: .track,
                qobuzID: "song",
                title: "Song",
                subtitle: "Artist",
                relativePath: sharedPath,
                trackPaths: [sharedPath]
            ),
            QobuzLibraryCollectionRecord(
                id: "playlist|mix",
                kind: .playlist,
                qobuzID: "mix",
                title: "Mix",
                subtitle: "1 track",
                relativePath: "Playlists/Mix [mix]",
                trackPaths: [sharedPath]
            )
        ]

        let library = QobuzArchiveLibrary(tracks: [track], collections: collections)

        XCTAssertEqual(library.count(of: .album), 1)
        XCTAssertEqual(library.count(of: .track), 1)
        XCTAssertEqual(library.count(of: .playlist), 1)
        XCTAssertTrue(library.entries.allSatisfy { $0.tracks.map(\.relativePath) == [sharedPath] })
    }

    func testProvenanceRoundTripPersistsArchiveKindAndUnclassifiedDataRemainsReadable() throws {
        let value = provenance(
            trackID: "single",
            albumID: "album",
            hash: String(repeating: "a", count: 64),
            collection: .track
        )
        let decoded = try JSONDecoder().decode(
            QobuzFileProvenance.self,
            from: JSONEncoder().encode(value)
        )
        XCTAssertEqual(decoded.archiveKind, .track)

        let unclassified = Data("""
        {
          "qobuzTrackID": "unclassified-track",
          "qobuzAlbumID": "unclassified-album",
          "formatID": 27,
          "bitDepth": 24,
          "samplingRate": 96,
          "sha256": "\(String(repeating: "b", count: 64))"
        }
        """.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(QobuzFileProvenance.self, from: unclassified).archiveKind,
            .unclassified
        )
    }

    func testArchiveCacheDecodesAnUnclassifiedTrack() throws {
        let unclassified = Data("""
        {
          "relativePath": "Artist/Album/01. Track.flac",
          "qobuzTrackID": "track",
          "qobuzAlbumID": "album",
          "formatID": 27,
          "bitDepth": 24,
          "samplingRate": 96,
          "expectedSHA256": "\(String(repeating: "c", count: 64))",
          "actualSHA256": "\(String(repeating: "c", count: 64))",
          "byteCount": 1234,
          "integrity": "verified"
        }
        """.utf8)

        let track = try JSONDecoder().decode(QobuzArchiveTrack.self, from: unclassified)

        XCTAssertEqual(track.archiveKind, .unclassified)
        XCTAssertEqual(track.qobuzTrackID, "track")
    }

    func testScannerClassifiesUnclassifiedOutputLayoutsIntoSeparateSections() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let albumFolder = root.appendingPathComponent("Adele/19", isDirectory: true)
        let trackFolder = root.appendingPathComponent("Adele", isDirectory: true)
        let playlistFolder = root.appendingPathComponent("Sunday Mix", isDirectory: true)
        try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: playlistFolder, withIntermediateDirectories: true)

        try writeUnclassifiedManifest(
            folder: albumFolder,
            filename: "01. Daydreamer.flac",
            trackID: "album-track",
            albumID: "19"
        )
        try writeUnclassifiedManifest(
            folder: trackFolder,
            filename: "Hello.flac",
            trackID: "single-track",
            albumID: "25"
        )
        try writeUnclassifiedManifest(
            folder: playlistFolder,
            filename: "01. Adele - Easy on Me.flac",
            trackID: "playlist-track",
            albumID: "30"
        )
        try Data("""
        #EXTM3U
        #EXTINF:221,Adele - Easy on Me
        01. Adele - Easy on Me.flac
        """.utf8).write(to: playlistFolder.appendingPathComponent("Sunday Mix.m3u"))

        let snapshot = try await QobuzArchiveScanner().scan(root: root)

        XCTAssertEqual(snapshot.albumCount, 1)
        XCTAssertEqual(snapshot.standaloneTrackCount, 1)
        XCTAssertEqual(snapshot.playlistCount, 1)
        XCTAssertEqual(snapshot.unclassifiedCount, 0)
        XCTAssertEqual(snapshot.tracks.first { $0.qobuzTrackID == "album-track" }?.archiveKind, .album)
        XCTAssertEqual(snapshot.tracks.first { $0.qobuzTrackID == "single-track" }?.archiveKind, .track)
        XCTAssertEqual(snapshot.tracks.first { $0.qobuzTrackID == "playlist-track" }?.archiveKind, .playlist)
    }

    func testAdoptionBuildsMissingIndexAndRemainsValidAfterRootMoves() async throws {
        let parent = temporaryRoot()
        let original = parent.appendingPathComponent("Original", isDirectory: true)
        let moved = parent.appendingPathComponent("Moved", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let albumFolder = original.appendingPathComponent("Artist/Album", isDirectory: true)
        try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
        try writeManifest(
            folder: albumFolder,
            filename: "01. Song.flac",
            trackID: "track",
            albumID: "album",
            collection: .album(id: QobuzID("album"), title: "Album")
        )

        let adopter = QobuzLibraryAdopter()
        let preview = try await adopter.inspect(root: original)

        XCTAssertEqual(preview.manifestAction, .create)
        XCTAssertEqual(preview.proposedCollectionCount, 1)
        XCTAssertEqual(preview.proposedManifest.collections.first?.id, "album|album")
        XCTAssertEqual(preview.proposedManifest.collections.first?.relativePath, "Artist/Album")

        let adopted = try await adopter.adopt(root: original)
        XCTAssertEqual(adopted.snapshot.collections, preview.proposedManifest.collections)
        XCTAssertEqual(adopted.snapshot.verifiedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: original.appendingPathComponent(QobuzLibraryManifestIO.filename).path
        ))

        try FileManager.default.moveItem(at: original, to: moved)
        let movedPreview = try await adopter.inspect(root: moved)
        XCTAssertEqual(movedPreview.manifestAction, .none)
        XCTAssertEqual(movedPreview.snapshot.rootPath, moved.standardizedFileURL.path)
        XCTAssertEqual(movedPreview.snapshot.verifiedCount, 1)
    }

    func testAdoptionRepairsUnreadableIndexAndReconstructsPlaylistReferences() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
        let playlistFolder = root.appendingPathComponent("Playlists/Evening [playlist-42]", isDirectory: true)
        try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: playlistFolder, withIntermediateDirectories: true)
        try writeManifest(
            folder: albumFolder,
            filename: "01. Song.flac",
            trackID: "track",
            albumID: "album",
            collection: .album(id: QobuzID("album"), title: "Album")
        )
        try Data("{broken".utf8).write(
            to: root.appendingPathComponent(QobuzLibraryManifestIO.filename)
        )
        try Data("""
        #EXTM3U
        #EXTINF:180,Artist - Song
        ../../Artist/Album/01. Song.flac
        """.utf8).write(to: playlistFolder.appendingPathComponent("Evening.m3u"))

        let adopter = QobuzLibraryAdopter()
        let preview = try await adopter.inspect(root: root)

        XCTAssertEqual(preview.manifestAction, .repair)
        XCTAssertEqual(Set(preview.proposedManifest.collections.map(\.id)), [
            "album|album", "playlist|playlist-42"
        ])
        let playlist = try XCTUnwrap(
            preview.proposedManifest.collections.first { $0.kind == .playlist }
        )
        XCTAssertEqual(playlist.title, "Evening")
        XCTAssertEqual(playlist.trackPaths, ["Artist/Album/01. Song.flac"])

        let result = try await adopter.adopt(root: root)
        XCTAssertFalse(result.snapshot.issues.contains {
            $0.relativePath == QobuzLibraryManifestIO.filename
        })
        XCTAssertEqual(result.snapshot.playlistCount, 1)
    }

    func testAdoptionReconcilesRelocatedAlbumAndPreservesLogicalPresentation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relocatedFolder = root.appendingPathComponent("New Artist/New Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: relocatedFolder, withIntermediateDirectories: true)
        try writeManifest(
            folder: relocatedFolder,
            filename: "01. Song.flac",
            trackID: "track",
            albumID: "album",
            collection: .album(id: QobuzID("album"), title: "Album")
        )
        try QobuzLibraryManifestIO.save(
            QobuzLibraryManifest(collections: [
                QobuzLibraryCollectionRecord(
                    id: "album|album",
                    kind: .album,
                    qobuzID: "album",
                    title: "Curated Album Title",
                    subtitle: "Original Artist · 1 track",
                    relativePath: "Old Artist/Old Folder",
                    trackPaths: ["Old Artist/Old Folder/01. Song.flac"],
                    collectionDescription: "Preserve this description"
                )
            ]),
            at: root
        )

        let adopter = QobuzLibraryAdopter()
        let preview = try await adopter.inspect(root: root)

        XCTAssertEqual(preview.manifestAction, .update)
        let record = try XCTUnwrap(preview.proposedManifest.collections.first)
        XCTAssertEqual(record.title, "Curated Album Title")
        XCTAssertEqual(record.collectionDescription, "Preserve this description")
        XCTAssertEqual(record.relativePath, "New Artist/New Folder")
        XCTAssertEqual(record.trackPaths, ["New Artist/New Folder/01. Song.flac"])
    }

    func testIncrementalScanReusesUnchangedIntegrityWhileFullVerificationRehashes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Artist/Album", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeManifest(
            folder: folder,
            filename: "01. Song.flac",
            trackID: "track",
            albumID: "album",
            collection: .album(id: QobuzID("album"), title: "Album")
        )
        let scanner = QobuzArchiveScanner()
        let initial = try await scanner.scan(root: root)
        let original = try XCTUnwrap(initial.tracks.first)
        let sentinel = String(repeating: "f", count: 64)
        let cached = QobuzArchiveTrack(
            relativePath: original.relativePath,
            qobuzTrackID: original.qobuzTrackID,
            qobuzAlbumID: original.qobuzAlbumID,
            formatID: original.formatID,
            bitDepth: original.bitDepth,
            samplingRate: original.samplingRate,
            expectedSHA256: original.expectedSHA256,
            actualSHA256: sentinel,
            byteCount: original.byteCount,
            modificationDate: original.modificationDate,
            integrity: .checksumMismatch,
            archiveKind: original.archiveKind,
            isLibraryManaged: original.isLibraryManaged
        )
        let cachedSnapshot = QobuzArchiveSnapshot(rootPath: initial.rootPath, tracks: [cached])

        let incremental = try await scanner.scan(root: root, reusing: cachedSnapshot)
        let verified = try await scanner.scan(root: root, reusing: nil)

        XCTAssertEqual(incremental.tracks.first?.actualSHA256, sentinel)
        XCTAssertEqual(incremental.tracks.first?.integrity, .checksumMismatch)
        XCTAssertEqual(verified.tracks.first?.actualSHA256, original.expectedSHA256)
        XCTAssertEqual(verified.tracks.first?.integrity, .verified)
    }

    func testDownloadCompletionRefreshInspectsOnlyChangedAudioFolders() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let changedFolder = root.appendingPathComponent("Artist/Changed", isDirectory: true)
        let untouchedFolder = root.appendingPathComponent("Artist/Untouched", isDirectory: true)
        try FileManager.default.createDirectory(at: changedFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: untouchedFolder, withIntermediateDirectories: true)
        try writeManifest(
            folder: changedFolder,
            filename: "01. Changed.flac",
            trackID: "changed",
            albumID: "changed-album",
            collection: .album(id: QobuzID("changed-album"), title: "Changed")
        )
        try writeManifest(
            folder: untouchedFolder,
            filename: "01. Untouched.flac",
            trackID: "untouched",
            albumID: "untouched-album",
            collection: .album(id: QobuzID("untouched-album"), title: "Untouched")
        )
        let scanner = QobuzArchiveScanner()
        let initial = try await scanner.scan(root: root)
        try Data("{now-broken".utf8).write(
            to: untouchedFolder.appendingPathComponent(QobuzProvenanceManifestIO.filename)
        )

        let incremental = try await scanner.scan(
            root: root,
            reusing: initial,
            changedAudioURLs: [changedFolder.appendingPathComponent("01. Changed.flac")]
        )
        let full = try await scanner.scan(root: root)

        XCTAssertEqual(Set(incremental.tracks.map(\.qobuzTrackID)), ["changed", "untouched"])
        XCTAssertFalse(incremental.issues.contains {
            $0.relativePath.hasPrefix("Artist/Untouched/")
        })
        XCTAssertEqual(full.tracks.map(\.qobuzTrackID), ["changed"])
        XCTAssertTrue(full.issues.contains {
            $0.relativePath.hasPrefix("Artist/Untouched/")
        })
    }

    private struct TestManifest: Encodable {
        let version = 1
        let files: [String: QobuzFileProvenance]
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OrpheusArchiveTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func provenance(
        trackID: String,
        albumID: String,
        hash: String,
        collection: QobuzCollection? = nil
    ) -> QobuzFileProvenance {
        let artist = QobuzArtist(id: QobuzID("artist"), name: "Artist")
        let album = QobuzAlbum(id: QobuzID(albumID), title: "Album", artist: artist)
        let track = QobuzTrack(id: QobuzID(trackID), title: "Track", performer: artist)
        let item = QobuzResolvedTrack(
            track: track,
            album: album,
            collection: collection ?? .album(id: album.id, title: album.title),
            position: 1,
            total: 1
        )
        return QobuzFileProvenance(
            item: item,
            delivery: try! validatedTestDelivery(
                for: QobuzFileInfo(
                    url: URL(string: "https://media.example/file.flac")!,
                    format: .hiRes,
                    bitDepth: 24,
                    samplingRate: 96
                )
            ),
            sha256: hash
        )
    }

    private func archiveTrack(
        relativePath: String = "track.flac",
        trackID: String,
        albumID: String,
        integrity: QobuzArchiveIntegrity,
        archiveKind: QobuzArchiveKind = .album
    ) -> QobuzArchiveTrack {
        QobuzArchiveTrack(
            relativePath: relativePath,
            qobuzTrackID: trackID,
            qobuzAlbumID: albumID,
            formatID: 27,
            expectedSHA256: String(repeating: "a", count: 64),
            actualSHA256: integrity == .verified ? String(repeating: "a", count: 64) : nil,
            integrity: integrity,
            archiveKind: archiveKind
        )
    }

    private func writeUnclassifiedManifest(
        folder: URL,
        filename: String,
        trackID: String,
        albumID: String
    ) throws {
        let audioURL = folder.appendingPathComponent(filename)
        try Data(filename.utf8).write(to: audioURL)
        let hash = try MusicFileIntegrity.sha256(of: audioURL)
        let manifest = """
        {
          "version": 1,
          "files": {
            "\(filename)": {
              "qobuzTrackID": "\(trackID)",
              "qobuzAlbumID": "\(albumID)",
              "formatID": 27,
              "bitDepth": 24,
              "samplingRate": 96,
              "sha256": "\(hash)"
            }
          }
        }
        """
        try Data(manifest.utf8).write(to: folder.appendingPathComponent(".orpheus-provenance.json"))
        try Data("\(hash)  \(filename)\n".utf8).write(
            to: folder.appendingPathComponent("checksums.sha256")
        )
    }

    private func writeManifest(
        folder: URL,
        filename: String,
        trackID: String,
        albumID: String,
        collection: QobuzCollection
    ) throws {
        let audioURL = folder.appendingPathComponent(filename)
        try Data(filename.utf8).write(to: audioURL)
        let hash = try MusicFileIntegrity.sha256(of: audioURL)
        let manifest = TestManifest(files: [
            filename: provenance(
                trackID: trackID,
                albumID: albumID,
                hash: hash,
                collection: collection
            )
        ])
        try JSONEncoder().encode(manifest).write(
            to: folder.appendingPathComponent(".orpheus-provenance.json")
        )
        try Data("\(hash)  \(filename)\n".utf8).write(
            to: folder.appendingPathComponent("checksums.sha256")
        )
    }
}
