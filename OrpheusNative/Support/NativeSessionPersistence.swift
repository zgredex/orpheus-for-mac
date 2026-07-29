import Foundation
import NativeQobuzCore

struct NativeSessionSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    var queue: [NativeQueueItem]
    var operations: [NativeDownloadOperation]
    var selectedQueueID: UUID?
    var linkInbox: [NativeLinkInboxItem]

    init(
        queue: [NativeQueueItem],
        operations: [NativeDownloadOperation],
        selectedQueueID: UUID?,
        linkInbox: [NativeLinkInboxItem]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.queue = queue
        self.operations = operations
        self.selectedQueueID = selectedQueueID
        self.linkInbox = linkInbox
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case queue
        case operations
        case selectedQueueID
        case linkInbox
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        queue = try container.decode([NativeQueueItem].self, forKey: .queue)
        operations = try container.decode([NativeDownloadOperation].self, forKey: .operations)
        selectedQueueID = try container.decodeIfPresent(UUID.self, forKey: .selectedQueueID)
        linkInbox = try container.decode([NativeLinkInboxItem].self, forKey: .linkInbox)
        try validate()
    }

    func validate() throws {
        let queueIDs = queue.map(\.id)
        let operationQueueIDs = operations.map(\.queueID)
        let operationActivityIDs = operations.compactMap(\.activityID)

        guard schemaVersion == Self.currentSchemaVersion else {
            throw NativeQobuzError.invalidResponse(
                "Unsupported download-session schema \(schemaVersion)."
            )
        }
        guard Set(queueIDs).count == queueIDs.count else {
            throw NativeQobuzError.invalidResponse("The download session contains duplicate queue IDs.")
        }
        guard Set(operationQueueIDs).count == operationQueueIDs.count else {
            throw NativeQobuzError.invalidResponse("The download session contains duplicate operation queue IDs.")
        }
        guard Set(operationActivityIDs).count == operationActivityIDs.count else {
            throw NativeQobuzError.invalidResponse("The download session contains duplicate operation Activity IDs.")
        }

        let queueIDSet = Set(queueIDs)
        let operationsByQueueID = Dictionary(uniqueKeysWithValues: operations.map { ($0.queueID, $0) })
        guard queueIDSet.allSatisfy({ operationsByQueueID[$0] != nil }) else {
            throw NativeQobuzError.invalidResponse("A queued item has no download operation.")
        }
        if let selectedQueueID, !queueIDSet.contains(selectedQueueID) {
            throw NativeQobuzError.invalidResponse("The selected queue ID does not exist in the session.")
        }
        for operation in operations {
            if operation.activityID == nil, !queueIDSet.contains(operation.queueID) {
                throw NativeQobuzError.invalidResponse("A download operation has no queue or Activity owner.")
            }
        }
    }
}

protocol NativeSessionStoring: Sendable {
    func load() throws -> NativeSessionSnapshot?
    func save(_ snapshot: NativeSessionSnapshot) throws
}

struct NativeSessionStore: NativeSessionStoring, Sendable {
    let paths: NativePaths
    private let files: NativeApplicationSupportFileStore

    init(paths: NativePaths) {
        self.paths = paths
        files = NativeApplicationSupportFileStore(rootURL: paths.applicationSupportRoot)
    }

    func load() throws -> NativeSessionSnapshot? {
        do {
            guard let data = try files.read(.session) else {
                qobuzLog.debug("persistence.session", "No saved download session exists")
                return nil
            }
            let snapshot = try JSONDecoder().decode(
                NativeSessionSnapshot.self,
                from: data
            )
            try snapshot.validate()
            qobuzLog.info(
                "persistence.session",
                "Download session restored",
                metadata: diagnosticMetadata(for: snapshot)
            )
            return snapshot
        } catch {
            do {
                let rejectedURL = try files.quarantine(
                    .session,
                    rejectedPrefix: "download-session.rejected"
                )
                qobuzLog.error(
                    "persistence.session",
                    "Rejected download session was quarantined; the app will start with a clean session",
                    metadata: [
                        "sessionPath": paths.sessionURL.path,
                        "rejectedPath": rejectedURL.path
                    ],
                    error: error
                )
                return nil
            } catch let quarantineError {
                qobuzLog.error(
                    "persistence.session",
                    "Invalid download session could not be quarantined",
                    metadata: ["sessionPath": paths.sessionURL.path],
                    error: quarantineError
                )
                throw error
            }
        }
    }

    func save(_ snapshot: NativeSessionSnapshot) throws {
        try snapshot.validate()
        try files.write(JSONEncoder.persistence.encode(snapshot), to: .session)
        qobuzLog.debug(
            "persistence.session",
            "Download session saved",
            metadata: diagnosticMetadata(for: snapshot)
        )
    }

    private func diagnosticMetadata(for snapshot: NativeSessionSnapshot) -> [String: String] {
        [
            "sessionPath": paths.sessionURL.path,
            "queueCount": String(snapshot.queue.count),
            "activityCount": String(snapshot.operations.count { $0.activityID != nil }),
            "operationCount": String(snapshot.operations.count),
            "inboxCount": String(snapshot.linkInbox.count),
            "schemaVersion": String(snapshot.schemaVersion)
        ]
    }
}
