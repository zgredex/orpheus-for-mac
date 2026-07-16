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

        try validateCollections(snapshot.collections, physicalTrackPaths: Set(paths))
    }

    static func validateCollections(
        _ collections: [QobuzLibraryCollectionRecord],
        physicalTrackPaths: Set<String>
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
            guard Set(collection.trackPaths).count == collection.trackPaths.count else {
                throw invalid("The cached archive index contains duplicate collection link records.")
            }
            guard collection.trackPaths.allSatisfy(physicalTrackPaths.contains) else {
                throw invalid("The cached archive index contains a link to a missing physical track.")
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
