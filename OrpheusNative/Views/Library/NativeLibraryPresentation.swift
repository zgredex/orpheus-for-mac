import NativeQobuzCore
import SwiftUI

enum NativeLibrarySection: String, CaseIterable, Hashable {
    case albums = "Albums"
    case tracks = "Tracks"
    case playlists = "Playlists"
    case older = "Older"
    case problems = "Problems"

    var title: String { rawValue }

    var archiveKind: QobuzArchiveKind? {
        switch self {
        case .albums: .album
        case .tracks: .track
        case .playlists: .playlist
        case .older: .unclassified
        case .problems: nil
        }
    }
}

enum NativeLibraryPresentation {
    static func visibleSections(in snapshot: QobuzArchiveSnapshot) -> [NativeLibrarySection] {
        var values: [NativeLibrarySection] = [.albums, .tracks, .playlists]
        if snapshot.library.count(of: .unclassified) > 0 { values.append(.older) }
        values.append(.problems)
        return values
    }

    static func count(_ section: NativeLibrarySection, in snapshot: QobuzArchiveSnapshot) -> Int {
        if section == .problems { return snapshot.problemCount }
        return section.archiveKind.map { snapshot.library.count(of: $0) } ?? 0
    }

    static func synchronizedSection(
        _ section: NativeLibrarySection,
        with snapshot: QobuzArchiveSnapshot
    ) -> NativeLibrarySection {
        guard section != .problems else { return section }
        let visible = visibleSections(in: snapshot)
        guard !visible.contains(section) || count(section, in: snapshot) == 0 else { return section }
        return visible.first { $0 != .problems && count($0, in: snapshot) > 0 } ?? .albums
    }

    static func label(for kind: QobuzArchiveKind) -> String {
        switch kind {
        case .album: "Albums"
        case .track: "Tracks"
        case .playlist: "Playlists"
        case .unclassified: "Older"
        }
    }

    static func icon(for kind: QobuzArchiveKind) -> String {
        switch kind {
        case .album: "square.stack"
        case .track: "music.note"
        case .playlist: "music.note.list"
        case .unclassified: "archivebox"
        }
    }

    static func emptyDescription(for kind: QobuzArchiveKind) -> String {
        switch kind {
        case .album: "Downloaded albums and artist releases appear here."
        case .track: "Individually downloaded tracks appear here."
        case .playlist: "Downloaded playlists appear here."
        case .unclassified: "Downloads without Library classification appear here."
        }
    }

    static func qualityKind(for entry: QobuzArchiveEntry) -> QualityBadge.Kind {
        let values = Set(entry.tracks.map(QualityBadge.Kind.archive))
        return values.count == 1 ? values.first ?? .mixed : .mixed
    }

    static func integrityPresentation(
        _ integrity: QobuzArchiveIntegrity
    ) -> (label: String, icon: String, color: Color) {
        switch integrity {
        case .verified: ("Verified", "checkmark.seal.fill", .green)
        case .missing: ("Missing", "questionmark.folder", .orange)
        case .checksumMismatch: ("Changed", "exclamationmark.triangle.fill", .red)
        case .metadataConflict: ("Conflict", "arrow.trianglehead.2.clockwise.rotate.90", .orange)
        case .unreadable: ("Unreadable", "xmark.octagon.fill", .red)
        }
    }
}

struct NativeLibraryIntegrityLabel: View {
    let integrity: QobuzArchiveIntegrity

    var body: some View {
        let value = NativeLibraryPresentation.integrityPresentation(integrity)
        Label(value.label, systemImage: value.icon)
            .font(.caption)
            .foregroundStyle(value.color)
    }
}
