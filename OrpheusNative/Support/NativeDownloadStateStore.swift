import Foundation

/// The only durable lifecycle record for a queued download and its optional
/// Activity projection. Queue and Activity payloads deliberately contain no
/// independent status field.
struct NativeDownloadOperation: Codable, Identifiable, Equatable, Sendable {
    let queueID: UUID
    var activityID: UUID?
    var status: NativeDownloadStatus

    var id: UUID { queueID }

    init(
        queueID: UUID,
        activityID: UUID? = nil,
        status: NativeDownloadStatus = .ready
    ) {
        self.queueID = queueID
        self.activityID = activityID
        self.status = status
    }
}

/// Focused owner for download lifecycle state. It intentionally has no UI or
/// persistence dependencies; `NativeDownloadLedger` publishes projections and
/// is the sole mutation boundary for the app's operation lifecycle.
struct NativeDownloadStateStore: Equatable {
    private var operationsByQueueID: [UUID: NativeDownloadOperation] = [:]

    init(operations: [NativeDownloadOperation] = []) {
        for operation in operations {
            operationsByQueueID[operation.queueID] = operation
        }
    }

    var operations: [NativeDownloadOperation] {
        operationsByQueueID.values.sorted {
            $0.queueID.uuidString < $1.queueID.uuidString
        }
    }

    func status(forQueueID queueID: UUID) -> NativeDownloadStatus {
        operationsByQueueID[queueID]?.status ?? .ready
    }

    func status(forActivityID activityID: UUID) -> NativeDownloadStatus? {
        operationsByQueueID.values.first { $0.activityID == activityID }?.status
    }

    func operation(forQueueID queueID: UUID) -> NativeDownloadOperation? {
        operationsByQueueID[queueID]
    }

    mutating func registerQueue(_ queueID: UUID, status: NativeDownloadStatus = .ready) {
        guard operationsByQueueID[queueID] == nil else { return }
        operationsByQueueID[queueID] = NativeDownloadOperation(queueID: queueID, status: status)
    }

    mutating func registerQueues<S: Sequence>(_ queueIDs: S) where S.Element == UUID {
        for queueID in queueIDs { registerQueue(queueID) }
    }

    mutating func bindActivity(
        _ activityID: UUID,
        to queueID: UUID,
        status: NativeDownloadStatus? = nil
    ) {
        var operation = operationsByQueueID[queueID]
            ?? NativeDownloadOperation(queueID: queueID)
        operation.activityID = activityID
        if let status { operation.status = status }
        operationsByQueueID[queueID] = operation
    }

    mutating func transition(
        queueID: UUID,
        activityID: UUID? = nil,
        to status: NativeDownloadStatus
    ) {
        var operation = operationsByQueueID[queueID]
            ?? NativeDownloadOperation(queueID: queueID)
        if let activityID { operation.activityID = activityID }
        operation.status = status
        operationsByQueueID[queueID] = operation
    }

    mutating func removeQueue(_ queueID: UUID) {
        guard let operation = operationsByQueueID[queueID] else { return }
        if operation.activityID == nil { operationsByQueueID.removeValue(forKey: queueID) }
    }

    mutating func removeActivity(_ activityID: UUID, queueStillExists: Bool) {
        guard let queueID = operationsByQueueID.first(where: { $0.value.activityID == activityID })?.key,
              var operation = operationsByQueueID[queueID] else { return }
        if queueStillExists {
            operation.activityID = nil
            operationsByQueueID[queueID] = operation
        } else {
            operationsByQueueID.removeValue(forKey: queueID)
        }
    }

    mutating func normalizeAfterInterruption() -> Set<UUID> {
        var interruptedActivityIDs = Set<UUID>()
        for queueID in Array(operationsByQueueID.keys) {
            guard var operation = operationsByQueueID[queueID] else { continue }
            switch operation.status {
            case let status where status.isActive:
                if let activityID = operation.activityID {
                    interruptedActivityIDs.insert(activityID)
                }
                operation.status = .paused
            default:
                break
            }
            operationsByQueueID[queueID] = operation
        }
        return interruptedActivityIDs
    }
}
