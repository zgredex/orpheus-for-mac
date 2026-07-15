import CryptoKit
import Foundation

struct QobuzRequestSigner: Sendable {
    private let appSecret: String
    private let timestamp: @Sendable () -> Int64

    init(appSecret: String, timestamp: @escaping @Sendable () -> Int64) {
        self.appSecret = appSecret
        self.timestamp = timestamp
    }

    func signedParameters(
        endpoint: String,
        parameters: [String: String]
    ) -> [String: String] {
        qobuzLog.trace(
            "api.signing",
            "Preparing signed Qobuz request",
            metadata: ["endpoint": endpoint, "parameterCount": String(parameters.count)]
        )
        let requestTimestamp = timestamp()
        var signed = parameters
        signed["request_ts"] = String(requestTimestamp)
        signed["request_sig"] = Self.signature(
            endpoint: endpoint,
            parameters: parameters,
            timestamp: requestTimestamp,
            appSecret: appSecret
        )
        return signed
    }

    static func signature(
        endpoint: String,
        parameters: [String: String],
        timestamp: Int64,
        appSecret: String
    ) -> String {
        var input = endpoint.replacingOccurrences(of: "/", with: "")
        for key in parameters.keys.sorted() where key != "app_id" && key != "user_auth_token" {
            input += key + (parameters[key] ?? "")
        }
        input += String(timestamp) + appSecret
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
