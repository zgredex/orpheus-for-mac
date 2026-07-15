import Foundation
import NativeQobuzCore

@MainActor
final class NativeBrowseNavigationController {
    private let browse: NativeBrowseController
    private let library: NativeLibraryController
    private var onFailure: ((String) -> Void)?

    init(browse: NativeBrowseController, library: NativeLibraryController) {
        self.browse = browse
        self.library = library
    }

    func configure(onFailure: @escaping (String) -> Void) {
        self.onFailure = onFailure
    }

    func search(_ query: String) {
        library.close()
        perform { try browse.search(query) }
    }

    func open(_ request: QobuzRequest) {
        library.close()
        perform { try browse.open(request) }
    }

    func open(_ destination: BrowseDestination) {
        library.close()
        perform { try browse.open(destination) }
    }

    func retryPage() {
        perform { try browse.retryPage() }
    }

    func retrySearch() {
        perform { try browse.retrySearch() }
    }

    func close() {
        browse.close()
    }

    func back() {
        browse.back()
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            onFailure?(error.localizedDescription)
        }
    }
}
