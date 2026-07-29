import Foundation

enum LibraryArtifactLimits {
    static let provenanceManifest = 8 * 1_024 * 1_024
    static let checksumManifest = 8 * 1_024 * 1_024
    static let playlist = 16 * 1_024 * 1_024
    static let description = 2 * 1_024 * 1_024
    static let libraryManifest = 128 * 1_024 * 1_024
}
