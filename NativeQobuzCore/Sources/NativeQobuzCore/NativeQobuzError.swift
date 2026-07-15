import Foundation

public enum NativeQobuzError: LocalizedError, Equatable, Sendable {
    case missingCredentials
    case invalidCredentials
    case freeAccount
    case unavailable(String)
    case invalidResponse(String)
    case http(Int, String)
    case connectivity(String)
    case network(String)
    case emptyCollection(String)
    case missingAlbum(QobuzID)
    case cancelled
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials: "Qobuz credentials are incomplete."
        case .invalidCredentials: "Qobuz credentials are invalid or expired."
        case .freeAccount: "This Qobuz account is not eligible for downloading."
        case .unavailable(let message): message
        case .invalidResponse(let message): "Invalid Qobuz response: \(message)"
        case .http(let status, let message): "Qobuz returned HTTP \(status): \(message)"
        case .connectivity(let message): "Network connection unavailable: \(message)"
        case .network(let message): "Could not reach Qobuz: \(message)"
        case .emptyCollection(let name): "Qobuz returned no downloadable tracks for \(name)."
        case .missingAlbum(let id): "Track metadata is missing album \(id.rawValue)."
        case .cancelled: "Download cancelled."
        case .fileSystem(let message): "File operation failed: \(message)"
        }
    }

    public var canResumeTransfer: Bool {
        switch self {
        case .connectivity, .network:
            true
        case .http(let status, _):
            status == 403 || status == 408 || status == 409 || status == 416
                || status == 425 || status == 429 || (500...599).contains(status)
        default:
            false
        }
    }

    public var isConnectivityLoss: Bool {
        if case .connectivity = self { return true }
        return false
    }

    public var requiresFreshSignedURL: Bool {
        if case .http(let status, _) = self { return status == 403 }
        return false
    }

    public static func networkFailure(_ error: Error) -> NativeQobuzError {
        let urlError = error as? URLError
            ?? ((error as NSError).domain == NSURLErrorDomain
                ? URLError(URLError.Code(rawValue: (error as NSError).code))
                : nil)
        guard let urlError else { return .network(error.localizedDescription) }
        let connectivityCodes: Set<URLError.Code> = [
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .networkConnectionLost,
            .notConnectedToInternet,
            .internationalRoamingOff,
            .callIsActive,
            .dataNotAllowed
        ]
        return connectivityCodes.contains(urlError.code)
            ? .connectivity(urlError.localizedDescription)
            : .network(urlError.localizedDescription)
    }
}
