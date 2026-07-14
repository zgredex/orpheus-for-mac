import Foundation

public extension Error {
    var isQobuzCancellation: Bool {
        if self is CancellationError { return true }
        if (self as? NativeQobuzError) == .cancelled { return true }
        let cocoaError = self as NSError
        return cocoaError.domain == NSURLErrorDomain
            && cocoaError.code == URLError.cancelled.rawValue
    }
}
