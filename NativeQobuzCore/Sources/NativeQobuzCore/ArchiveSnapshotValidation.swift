import Foundation

/// The single trust boundary for persisted archive projections.
/// Physical files may be shared by collections, but physical paths, collection
/// identities, and links within one collection must each remain unambiguous.
public enum QobuzArchiveSnapshotValidation {
    public static func validate(_ snapshot: QobuzArchiveSnapshot) throws {
        guard snapshot.version == 1 else {
            throw invalid("Unsupported archive index version \(snapshot.version).")
        }
        guard !snapshot.rootPath.isEmpty, snapshot.rootPath.hasPrefix("/") else {
            throw invalid("The cached archive index has an invalid Library root.")
        }

        let paths = snapshot.tracks.map(\.relativePath)
        guard Set(paths).count == paths.count else {
            throw invalid("The cached archive index contains duplicate physical track paths.")
        }
        guard paths.allSatisfy(QobuzPathSafety.isSafeRelativePath) else {
            throw invalid("The cached archive index contains an unsafe track path.")
        }
        guard snapshot.tracks.allSatisfy({
            !$0.qobuzTrackID.isEmpty && !$0.qobuzAlbumID.isEmpty
        }) else {
            throw invalid("The cached archive index contains an empty Qobuz track or album ID.")
        }
        var aggregateBytes: Int64 = 0
        for track in snapshot.tracks {
            if let byteCount = track.byteCount {
                guard byteCount >= 0 else {
                    throw invalid("The cached archive index contains a negative file size.")
                }
                let (updated, overflow) = aggregateBytes.addingReportingOverflow(byteCount)
                guard !overflow else {
                    throw invalid("The cached archive index contains overflowing file sizes.")
                }
                aggregateBytes = updated
            }
            if let bitDepth = track.bitDepth, !(1...64).contains(bitDepth) {
                throw invalid("The cached archive index contains an invalid audio bit depth.")
            }
            if let samplingRate = track.samplingRate,
               !samplingRate.isFinite || samplingRate <= 0 || samplingRate > 1_000_000 {
                throw invalid("The cached archive index contains an invalid audio sample rate.")
            }
        }

        try validateCollections(snapshot.collections, physicalTrackPaths: Set(paths))
    }

    static func validateCollections(
        _ collections: [QobuzLibraryCollectionRecord],
        physicalTrackPaths: Set<String>
    ) throws {
        try validateCollectionStructure(collections)
        for collection in collections {
            guard collection.trackPaths.allSatisfy(physicalTrackPaths.contains) else {
                throw invalid("The cached archive index contains a link to a missing physical track.")
            }
        }
    }

    /// Validates collection identity and internal link shape without requiring
    /// the linked files to remain at their recorded paths. Adoption uses this
    /// boundary so a consistently relocated collection can retain its curated
    /// presentation while genuinely malformed records are still discarded.
    static func validateCollectionStructure(
        _ collections: [QobuzLibraryCollectionRecord]
    ) throws {
        let collectionIDs = collections.map(\.id)
        guard Set(collectionIDs).count == collectionIDs.count else {
            throw invalid("The cached archive index contains duplicate collection IDs.")
        }

        for collection in collections {
            guard !collection.qobuzID.isEmpty,
                  collection.id == "\(collection.kind.rawValue)|\(collection.qobuzID)" else {
                throw invalid("The cached archive index contains an invalid collection identity.")
            }
            let assetPaths = [collection.relativePath]
                + collection.trackPaths
                + [collection.artworkRelativePath].compactMap { $0 }
            guard assetPaths.allSatisfy(QobuzPathSafety.isSafeRelativePath) else {
                throw invalid("The cached archive index contains an unsafe collection path.")
            }
            guard collection.kind == .playlist
                    || Set(collection.trackPaths).count == collection.trackPaths.count else {
                throw invalid("The cached archive index contains duplicate collection link records.")
            }
            if let artwork = collection.artworkRelativePath,
               QobuzPathSafety.directoryPath(of: artwork)
                != (try QobuzManagedLibraryAssetPolicy.assetFolder(for: collection)).rawValue {
                throw invalid("The cached archive index contains artwork outside its collection folder.")
            }
            switch collection.kind {
            case .album:
                guard !collection.trackPaths.isEmpty,
                      collection.trackPaths.allSatisfy({
                        QobuzPathSafety.directoryPath(of: $0) == collection.relativePath
                      }) else {
                    throw invalid("The cached archive index contains an album linked outside its folder.")
                }
            case .track:
                guard collection.trackPaths == [collection.relativePath] else {
                    throw invalid("The cached archive index contains an invalid standalone-track link.")
                }
            case .playlist:
                guard !collection.trackPaths.isEmpty else {
                    throw invalid("The cached archive index contains an empty playlist record.")
                }
            case .unclassified:
                throw invalid("The cached archive index contains an unclassified logical collection.")
            }
        }
    }

    private static func invalid(_ message: String) -> NativeQobuzError {
        .invalidResponse(message)
    }
}

public extension QobuzArchiveSnapshot {
    func validate() throws {
        try QobuzArchiveSnapshotValidation.validate(self)
    }
}
