import Foundation

/// Focused owner for download lifecycle state. Queue and Activity identifiers
/// are indexed once when membership changes; telemetry updates do not resort
/// the complete operation collection.
struct NativeDownloadStateStore: Equatable {
    private var operationsByQueueID: [UUID: NativeDownloadOperation] = [:]
    private var queueIDByActivityID: [UUID: UUID] = [:]
    private var orderedQueueIDs: [UUID] = []
    private var orderedActivityQueueIDs: [UUID] = []
    private(set) var revision: UInt64 = 0

    init(operations: [NativeDownloadOperation] = []) {
        for operation in operations {
            operationsByQueueID[operation.queueID] = operation
        }
        rebuildIndexes()
    }

    var operations: [NativeDownloadOperation] {
        orderedQueueIDs.compactMap { operationsByQueueID[$0] }
    }

    var activities: [NativeDownloadActivity] {
        orderedActivityQueueIDs.compactMap {
            operationsByQueueID[$0].map(NativeDownloadActivity.init(operation:))
        }
    }

    func status(forQueueID queueID: UUID) -> NativeDownloadStatus {
        operationsByQueueID[queueID]?.status ?? .ready
    }

    func status(forActivityID activityID: UUID) -> NativeDownloadStatus? {
        operation(forActivityID: activityID)?.status
    }

    func operation(forQueueID queueID: UUID) -> NativeDownloadOperation? {
        operationsByQueueID[queueID]
    }

    func operation(forActivityID activityID: UUID) -> NativeDownloadOperation? {
        queueIDByActivityID[activityID].flatMap { operationsByQueueID[$0] }
    }

    mutating func registerQueue(_ queueID: UUID, status: NativeDownloadStatus = .ready) {
        guard operationsByQueueID[queueID] == nil else { return }
        operationsByQueueID[queueID] = NativeDownloadOperation(queueID: queueID, status: status)
        orderedQueueIDs.append(queueID)
        orderedQueueIDs.sort(by: Self.queueOrder)
        changed()
    }

    mutating func registerQueues<S: Sequence>(_ queueIDs: S) where S.Element == UUID {
        var inserted = false
        for queueID in queueIDs where operationsByQueueID[queueID] == nil {
            operationsByQueueID[queueID] = NativeDownloadOperation(queueID: queueID)
            orderedQueueIDs.append(queueID)
            inserted = true
        }
        guard inserted else { return }
        orderedQueueIDs.sort(by: Self.queueOrder)
        changed()
    }

    mutating func bindActivity(
        _ activityID: UUID,
        to queueID: UUID,
        status: NativeDownloadStatus? = nil
    ) {
        var operation = operationsByQueueID[queueID]
            ?? NativeDownloadOperation(queueID: queueID)
        operation.activityID = activityID
        operation.activityCreatedAt = operation.activityCreatedAt ?? Date()
        if let status { operation.status = status }
        set(operation, for: queueID, activityOrderingMayChange: true)
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
        set(
            operation,
            for: queueID,
            activityOrderingMayChange: activityID != nil
        )
    }

    mutating func mutateOperation(
        queueID: UUID,
        _ mutate: (inout NativeDownloadOperation) -> Void
    ) {
        guard var operation = operationsByQueueID[queueID] else { return }
        let previousActivityID = operation.activityID
        let previousCreatedAt = operation.activityCreatedAt
        mutate(&operation)
        set(
            operation,
            for: queueID,
            activityOrderingMayChange: previousActivityID != operation.activityID
                || previousCreatedAt != operation.activityCreatedAt
        )
    }

    mutating func removeQueue(_ queueID: UUID) {
        guard let operation = operationsByQueueID[queueID], operation.activityID == nil else { return }
        operationsByQueueID.removeValue(forKey: queueID)
        rebuildIndexes()
        changed()
    }

    mutating func removeActivity(_ activityID: UUID, queueStillExists: Bool) {
        guard let queueID = queueIDByActivityID[activityID],
              var operation = operationsByQueueID[queueID] else { return }
        if queueStillExists {
            operation.clearActivity()
            operationsByQueueID[queueID] = operation
        } else {
            operationsByQueueID.removeValue(forKey: queueID)
        }
        rebuildIndexes()
        changed()
    }

    mutating func normalizeAfterInterruption() -> Set<UUID> {
        var interruptedActivityIDs = Set<UUID>()
        for queueID in orderedQueueIDs {
            guard var operation = operationsByQueueID[queueID], operation.status.isActive else {
                continue
            }
            if let activityID = operation.activityID {
                interruptedActivityIDs.insert(activityID)
            }
            operation.status = .paused
            operation.phase = "Paused after interruption"
            operation.bytesPerSecond = nil
            operationsByQueueID[queueID] = operation
        }
        if !interruptedActivityIDs.isEmpty { changed() }
        return interruptedActivityIDs
    }

    private mutating func set(
        _ operation: NativeDownloadOperation,
        for queueID: UUID,
        activityOrderingMayChange: Bool
    ) {
        let previous = operationsByQueueID[queueID]
        guard previous != operation else { return }
        let isNewQueue = previous == nil
        operationsByQueueID[queueID] = operation
        if isNewQueue {
            orderedQueueIDs.append(queueID)
            orderedQueueIDs.sort(by: Self.queueOrder)
        }
        if activityOrderingMayChange {
            rebuildActivityIndex()
        }
        changed()
    }

    private mutating func rebuildIndexes() {
        orderedQueueIDs = operationsByQueueID.keys.sorted(by: Self.queueOrder)
        rebuildActivityIndex()
    }

    private mutating func rebuildActivityIndex() {
        queueIDByActivityID.removeAll(keepingCapacity: true)
        orderedActivityQueueIDs = operationsByQueueID.values
            .filter { $0.activityID != nil }
            .sorted(by: Self.activityOrder)
            .map { operation in
                if let activityID = operation.activityID {
                    queueIDByActivityID[activityID] = operation.queueID
                }
                return operation.queueID
            }
    }

    private mutating func changed() {
        revision &+= 1
    }

    private static func queueOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }

    private static func activityOrder(
        _ lhs: NativeDownloadOperation,
        _ rhs: NativeDownloadOperation
    ) -> Bool {
        let lhsCreatedAt = lhs.activityCreatedAt ?? .distantPast
        let rhsCreatedAt = rhs.activityCreatedAt ?? .distantPast
        if lhsCreatedAt != rhsCreatedAt { return lhsCreatedAt > rhsCreatedAt }
        return queueOrder(lhs.queueID, rhs.queueID)
    }
}
