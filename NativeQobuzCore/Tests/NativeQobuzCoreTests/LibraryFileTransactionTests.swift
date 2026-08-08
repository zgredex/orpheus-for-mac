import Foundation
import XCTest
@testable import NativeQobuzCore

final class LibraryFileTransactionTests: XCTestCase {
    func testCancellationRestoresOriginalAndStagedReplacement() async throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanup() }
        let original = try LibraryRelativePath("Artist/Album/song.flac")
        let source = try LibraryRelativePath("Artist/Album/song.partial")
        let originalData = Data("original audio".utf8)
        let replacementData = Data("replacement audio".utf8)
        try fixture.files.writeAtomically(originalData, to: original)
        try fixture.files.writeAtomically(replacementData, to: source)
        let mutation = try LibraryFileTransactionMutation.capture(
            path: original,
            finalState: .stagedFile(
                path: source,
                sha256: MusicFileIntegrity.sha256(of: replacementData)
            ),
            in: fixture.files
        )

        do {
            _ = try await LibraryFileTransaction(fileSystem: fixture.files).prepare(
                plan: LibraryFileTransactionPlan(operation: "test-cancellation", mutations: [mutation])
            ) {
                throw CancellationError()
            }
            XCTFail("Cancellation should abort the transaction")
        } catch is CancellationError {}

        XCTAssertEqual(try fixture.files.read(original), originalData)
        XCTAssertEqual(try fixture.files.read(source), replacementData)
        XCTAssertTrue(try fixture.transactionDirectories().isEmpty)
    }

    func testRecoveryRemovesInterruptedEmptyJournalDirectory() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanup() }
        let directory = try fixture.makeTransactionDirectory()

        try LibraryFileTransaction.recoverInterruptedTransactions(in: fixture.files)

        XCTAssertNil(try fixture.files.metadata(at: directory))
    }

    func testRecoveryRemovesOnlyRecognizedAtomicJournalTemporary() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanup() }
        let directory = try fixture.makeTransactionDirectory()
        let filename = ".\(LibraryFileTransactionJournal.filename).\(UUID().uuidString).partial"
        try fixture.files.writeAtomically(Data("incomplete".utf8), to: directory.appending(filename))

        try LibraryFileTransaction.recoverInterruptedTransactions(in: fixture.files)

        XCTAssertNil(try fixture.files.metadata(at: directory))
    }

    func testRecoveryPreservesAndRejectsUnknownTransactionContent() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanup() }
        let directory = try fixture.makeTransactionDirectory()
        let unexpected = try directory.appending("unknown.txt")
        try fixture.files.writeAtomically(Data("do not delete".utf8), to: unexpected)

        XCTAssertThrowsError(try LibraryFileTransaction.recoverInterruptedTransactions(in: fixture.files))
        XCTAssertEqual(try fixture.files.read(unexpected), Data("do not delete".utf8))
    }

    func testPublicRecoveryDoesNotHideMissingFilesInsidePersistedTransaction() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanup() }
        let original = try LibraryRelativePath("Artist/Album/missing.flac")
        let mutation = LibraryFileTransactionMutation(
            path: original,
            expectedOriginal: .regularFile(sha256: String(repeating: "0", count: 64)),
            finalState: .absent
        )
        let journal = try LibraryFileTransactionJournalBuilder().make(
            LibraryFileTransactionPlan(operation: "test-missing-recovery", mutations: [mutation])
        )
        try LibraryFileTransactionJournalStore(fileSystem: fixture.files).create(journal)

        XCTAssertThrowsError(try QobuzLibraryMutationRecovery.recover(at: fixture.root)) { error in
            guard case LibraryFileSystemError.missing(let path) = error else {
                return XCTFail("Expected a missing transaction file, got \(error)")
            }
            XCTAssertEqual(path, original.rawValue)
        }
        XCTAssertNotNil(try fixture.files.metadata(at: journal.journalPath))
    }

    func testRecoveryRollsBackFullyAppliedPreparedTransaction() async throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanup() }
        let files = try fixture.replacementMutation()
        let prepared = try await LibraryFileTransaction(fileSystem: fixture.files).prepare(
            plan: LibraryFileTransactionPlan(operation: "test-prepared-recovery", mutations: [files.mutation])
        ) {}

        try LibraryFileTransaction.recoverInterruptedTransactions(in: fixture.files)

        XCTAssertEqual(try fixture.files.read(files.destination), files.originalData)
        XCTAssertEqual(try fixture.files.read(files.source), files.replacementData)
        XCTAssertNil(try fixture.files.metadata(at: prepared.token.directory))
    }

    func testRecoveryRollsBackMutationAppliedBeforePreparedMarker() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanup() }
        let files = try fixture.replacementMutation()
        let plan = LibraryFileTransactionPlan(
            operation: "test-staging-recovery",
            mutations: [files.mutation]
        )
        let journal = try LibraryFileTransactionJournalBuilder().make(plan)
        let store = LibraryFileTransactionJournalStore(fileSystem: fixture.files)
        let executor = LibraryFileTransactionExecutor(fileSystem: fixture.files)
        try store.create(journal)
        try executor.stageOriginals(journal)
        XCTAssertThrowsError(try executor.applyFinalState(journal, mutations: plan.mutations) { _ in
            throw TransactionInterruption.injected
        })

        try LibraryFileTransaction.recoverInterruptedTransactions(in: fixture.files)

        XCTAssertEqual(try fixture.files.read(files.destination), files.originalData)
        XCTAssertEqual(try fixture.files.read(files.source), files.replacementData)
        XCTAssertNil(try fixture.files.metadata(at: journal.directory))
    }

    func testRecoveryFinishesTransactionAfterDurableCommitMarker() async throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanup() }
        let files = try fixture.replacementMutation()
        let transaction = LibraryFileTransaction(fileSystem: fixture.files)
        let prepared = try await transaction.prepare(
            plan: LibraryFileTransactionPlan(operation: "test-committing-recovery", mutations: [files.mutation])
        ) {}
        try transaction.prepareCommit(prepared.token)

        try LibraryFileTransaction.recoverInterruptedTransactions(in: fixture.files)

        XCTAssertEqual(try fixture.files.read(files.destination), files.replacementData)
        XCTAssertNil(try fixture.files.metadata(at: files.source))
        XCTAssertNil(try fixture.files.metadata(at: prepared.token.directory))
    }
}

private enum TransactionInterruption: Error { case injected }

private struct TransactionFixture {
    let root: URL
    let files: LibraryFileSystem

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryFileTransactionTests-\(UUID().uuidString)", isDirectory: true)
        files = try LibraryFileSystem(rootURL: root)
    }

    func makeTransactionDirectory() throws -> LibraryRelativePath {
        let directory = try LibraryRelativePath(
            LibraryFileTransactionJournal.directoryPrefix + UUID().uuidString.lowercased()
        )
        try files.createDirectory(directory)
        return directory
    }

    func transactionDirectories() throws -> [LibraryDirectoryEntry] {
        try files.entries(in: .root).filter {
            $0.path.lastComponent?.hasPrefix(LibraryFileTransactionJournal.directoryPrefix) == true
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func replacementMutation() throws -> (
        destination: LibraryRelativePath,
        source: LibraryRelativePath,
        originalData: Data,
        replacementData: Data,
        mutation: LibraryFileTransactionMutation
    ) {
        let destination = try LibraryRelativePath("Artist/Album/song.flac")
        let source = try LibraryRelativePath("Artist/Album/song.processing")
        let originalData = Data("original".utf8)
        let replacementData = Data("replacement".utf8)
        try files.writeAtomically(originalData, to: destination)
        try files.writeAtomically(replacementData, to: source)
        let mutation = try LibraryFileTransactionMutation.capture(
            path: destination,
            finalState: .stagedFile(
                path: source,
                sha256: MusicFileIntegrity.sha256(of: replacementData)
            ),
            in: files
        )
        return (destination, source, originalData, replacementData, mutation)
    }
}
