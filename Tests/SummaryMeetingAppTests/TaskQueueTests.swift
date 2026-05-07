import XCTest
@testable import SummaryMeetingApp

@MainActor
final class TaskQueueTests: XCTestCase {

    private var store: MeetingStore!
    private var queue: TaskQueue!

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_tasks_\(UUID().uuidString).sqlite")
        store = try MeetingStore(dbURL: url)
        queue = TaskQueue(dbQueue: store.dbQueue)
    }

    override func tearDown() {
        queue = nil
        store = nil
    }

    // MARK: - upsert / fetch

    func testUpsert_createsTask() {
        let id = MeetingID.new()
        queue.upsert(ProcessingTask(meetingID: id, stage: .transcribing))

        let t = queue.task(for: id)
        XCTAssertNotNil(t)
        XCTAssertEqual(t?.stage, .transcribing)
        XCTAssertEqual(t?.state, .running)
        XCTAssertEqual(t?.attempts, 1)
    }

    func testUpsert_overwritesExisting() {
        let id = MeetingID.new()
        queue.upsert(ProcessingTask(meetingID: id, stage: .transcribing))
        queue.upsert(ProcessingTask(meetingID: id, stage: .summarizing))

        let t = queue.task(for: id)
        XCTAssertEqual(t?.stage, .summarizing)
    }

    // MARK: - updateStage

    func testUpdateStage() {
        let id = MeetingID.new()
        queue.upsert(ProcessingTask(meetingID: id, stage: .transcribing))
        queue.updateStage(meetingID: id, stage: .summarizing)

        XCTAssertEqual(queue.task(for: id)?.stage, .summarizing)
    }

    // MARK: - markCompleted / markFailed

    func testMarkCompleted_removesFromPending() {
        let id = MeetingID.new()
        queue.upsert(ProcessingTask(meetingID: id, stage: .summarizing))
        queue.markCompleted(meetingID: id)

        let pending = queue.pendingTasks()
        XCTAssertFalse(pending.contains(where: { $0.meetingID == id }))
        XCTAssertEqual(queue.task(for: id)?.state, .completed)
    }

    func testMarkFailed_setsErrorAndState() {
        let id = MeetingID.new()
        queue.upsert(ProcessingTask(meetingID: id, stage: .transcribing))
        queue.markFailed(meetingID: id, error: "timeout")

        let t = queue.task(for: id)
        XCTAssertEqual(t?.state, .failed)
        XCTAssertEqual(t?.lastError, "timeout")
    }

    // MARK: - pendingTasks

    func testPendingTasks_onlyReturnsRunning() {
        let runID = MeetingID.new()
        let doneID = MeetingID.new()
        let failID = MeetingID.new()

        queue.upsert(ProcessingTask(meetingID: runID,  stage: .summarizing))
        queue.upsert(ProcessingTask(meetingID: doneID, stage: .summarizing))
        queue.upsert(ProcessingTask(meetingID: failID, stage: .transcribing))
        queue.markCompleted(meetingID: doneID)
        queue.markFailed(meetingID: failID, error: "err")

        let pending = queue.pendingTasks()
        XCTAssertTrue(pending.contains(where: { $0.meetingID == runID }))
        XCTAssertFalse(pending.contains(where: { $0.meetingID == doneID }))
        XCTAssertFalse(pending.contains(where: { $0.meetingID == failID }))
    }
}
