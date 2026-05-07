import XCTest
@testable import SummaryMeetingApp

@MainActor
final class MeetingStoreTests: XCTestCase {

    private var store: MeetingStore!

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_store_\(UUID().uuidString).sqlite")
        store = try MeetingStore(dbURL: url)
    }

    override func tearDown() {
        store = nil
    }

    // MARK: - meetings CRUD

    func testUpsertAndFetch() throws {
        let id = MeetingID.new()
        let m = Meeting(id: id, title: "Test Meeting", createdAt: Date(), status: .completed)
        try store.upsert(m)

        let fetched = try store.meeting(id: id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Test Meeting")
        XCTAssertEqual(fetched?.status, .completed)
    }

    func testListMeetings_orderedByCreatedAtDesc() throws {
        let earlier = Meeting(id: .new(), title: "Earlier",
                              createdAt: Date(timeIntervalSinceNow: -100), status: .completed)
        let later   = Meeting(id: .new(), title: "Later",
                              createdAt: Date(), status: .completed)
        try store.upsert(earlier)
        try store.upsert(later)

        let list = try store.listMeetings()
        XCTAssertGreaterThanOrEqual(list.count, 2)
        // 最新的排在前面
        XCTAssertEqual(list.first?.title, "Later")
    }

    func testUpsert_updatesExistingRow() throws {
        let id = MeetingID.new()
        var m = Meeting(id: id, title: "Original", createdAt: Date(), status: .processing)
        try store.upsert(m)
        m.title = "Updated"
        m.status = .completed
        try store.upsert(m)

        let fetched = try store.meeting(id: id)
        XCTAssertEqual(fetched?.title, "Updated")
        XCTAssertEqual(fetched?.status, .completed)
    }

    // MARK: - summary versions

    func testAddAndListSummaryVersions() throws {
        let id = MeetingID.new()
        try store.upsert(Meeting(id: id, title: "T", createdAt: Date(), status: .completed))

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sum_\(UUID().uuidString).md")
        try "# Summary".write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        _ = try store.addSummaryVersion(meetingID: id, path: tmpURL,
                                        model: "gemma", promptHash: "abc")
        _ = try store.addSummaryVersion(meetingID: id, path: tmpURL,
                                        model: "gemma", promptHash: "def")

        let versions = try store.allSummaryVersions(meetingID: id)
        XCTAssertEqual(versions.count, 2)
        // allSummaryVersions 应升序（最旧在前）
        XCTAssertEqual(versions[0].promptHash, "abc")
        XCTAssertEqual(versions[1].promptHash, "def")
    }

    func testLatestSummary_returnsNewest() throws {
        let id = MeetingID.new()
        try store.upsert(Meeting(id: id, title: "T", createdAt: Date(), status: .completed))

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("s_\(UUID().uuidString).md")
        try "x".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try store.addSummaryVersion(meetingID: id, path: tmp, model: "m", promptHash: "v1")
        Thread.sleep(forTimeInterval: 0.01)   // 确保 created_at 不同
        _ = try store.addSummaryVersion(meetingID: id, path: tmp, model: "m", promptHash: "v2")

        let latest = try store.latestSummary(meetingID: id)
        XCTAssertEqual(latest?.promptHash, "v2")
    }
}
