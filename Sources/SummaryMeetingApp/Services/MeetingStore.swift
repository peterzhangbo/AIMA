import Foundation
import GRDB

public struct TranscriptVersion: Identifiable, Sendable, Equatable {
    public var id: Int64
    public var meetingID: String
    public var kind: String  // "raw" | "clean" | "multispk"
    public var path: String
    public var createdAt: Date
    public var note: String?
}

public struct SummaryVersion: Identifiable, Sendable, Equatable {
    public var id: Int64
    public var meetingID: String
    public var path: String
    public var model: String?
    public var promptHash: String?
    public var createdAt: Date
    public var note: String?
}

@MainActor
public final class MeetingStore {
    private(set) var dbQueue: DatabaseQueue

    public init(dbURL: URL) throws {
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.dbQueue = try DatabaseQueue(path: dbURL.path)
        try migrate()
    }

    public static func defaultDBURL() -> URL {
        let root = SessionPaths.defaultRoot().deletingLastPathComponent()
        return root.appendingPathComponent("summary_meeting.sqlite")
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "meetings") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("duration_ms", .integer).notNull().defaults(to: 0)
                t.column("status", .text).notNull()
                t.column("audio_path", .text)
                t.column("failure_reason", .text)
            }
            try db.create(table: "transcript_versions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull().indexed()
                t.column("kind", .text).notNull()
                t.column("path", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("note", .text)
            }
            try db.create(table: "summary_versions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull().indexed()
                t.column("path", .text).notNull()
                t.column("model", .text)
                t.column("prompt_hash", .text)
                t.column("created_at", .datetime).notNull()
                t.column("note", .text)
            }
        }
        migrator.registerMigration("v2") { db in
            try db.create(table: "tasks") { t in
                t.column("meeting_id", .text).primaryKey()
                t.column("stage", .text).notNull()
                t.column("state", .text).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 1)
                t.column("last_error", .text)
                t.column("updated_at", .datetime).notNull()
            }
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: Meetings

    public func upsert(_ meeting: Meeting) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO meetings (id, title, created_at, duration_ms, status, audio_path, failure_reason)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title=excluded.title,
                    duration_ms=excluded.duration_ms,
                    status=excluded.status,
                    audio_path=excluded.audio_path,
                    failure_reason=excluded.failure_reason
                """,
                arguments: [
                    meeting.id.raw,
                    meeting.title,
                    meeting.createdAt,
                    meeting.durationMs,
                    meeting.status.rawValue,
                    meeting.audioPath,
                    meeting.failureReason
                ])
        }
    }

    public func deleteMeeting(id: MeetingID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM meetings WHERE id=?", arguments: [id.raw])
            try db.execute(sql: "DELETE FROM tasks WHERE meeting_id=?", arguments: [id.raw])
        }
    }

    public func listMeetings() throws -> [Meeting] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM meetings ORDER BY created_at DESC")
            return rows.map { Self.rowToMeeting($0) }
        }
    }

    public func meeting(id: MeetingID) throws -> Meeting? {
        try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM meetings WHERE id = ?", arguments: [id.raw]) {
                return Self.rowToMeeting(row)
            }
            return nil
        }
    }

    private static func rowToMeeting(_ row: Row) -> Meeting {
        Meeting(
            id: MeetingID(row["id"]),
            title: row["title"],
            createdAt: row["created_at"],
            durationMs: row["duration_ms"],
            status: MeetingStatus(rawValue: row["status"]) ?? .completed,
            audioPath: row["audio_path"],
            failureReason: row["failure_reason"]
        )
    }

    // MARK: Transcript versions

    @discardableResult
    public func addTranscriptVersion(meetingID: MeetingID, kind: String, path: URL, note: String? = nil) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcript_versions (meeting_id, kind, path, created_at, note)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [meetingID.raw, kind, path.path, Date(), note])
            return db.lastInsertedRowID
        }
    }

    public func latestTranscript(meetingID: MeetingID, kind: String? = nil) throws -> TranscriptVersion? {
        try dbQueue.read { db in
            let sql: String
            let args: StatementArguments
            if let kind = kind {
                sql = "SELECT * FROM transcript_versions WHERE meeting_id = ? AND kind = ? ORDER BY created_at DESC LIMIT 1"
                args = [meetingID.raw, kind]
            } else {
                sql = "SELECT * FROM transcript_versions WHERE meeting_id = ? ORDER BY created_at DESC LIMIT 1"
                args = [meetingID.raw]
            }
            if let row = try Row.fetchOne(db, sql: sql, arguments: args) {
                return TranscriptVersion(
                    id: row["id"],
                    meetingID: row["meeting_id"],
                    kind: row["kind"],
                    path: row["path"],
                    createdAt: row["created_at"],
                    note: row["note"]
                )
            }
            return nil
        }
    }

    public func allTranscriptVersions(meetingID: MeetingID, kind: String) throws -> [TranscriptVersion] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM transcript_versions WHERE meeting_id = ? AND kind = ? ORDER BY created_at ASC", arguments: [meetingID.raw, kind])
            return rows.map { row in
                TranscriptVersion(
                    id: row["id"],
                    meetingID: row["meeting_id"],
                    kind: row["kind"],
                    path: row["path"],
                    createdAt: row["created_at"],
                    note: row["note"]
                )
            }
        }
    }

    // MARK: Summary versions

    @discardableResult
    public func addSummaryVersion(meetingID: MeetingID, path: URL, model: String?, promptHash: String?, note: String? = nil) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO summary_versions (meeting_id, path, model, prompt_hash, created_at, note)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [meetingID.raw, path.path, model, promptHash, Date(), note])
            return db.lastInsertedRowID
        }
    }

    public func latestSummary(meetingID: MeetingID) throws -> SummaryVersion? {
        try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM summary_versions WHERE meeting_id = ? ORDER BY created_at DESC LIMIT 1", arguments: [meetingID.raw]) {
                return SummaryVersion(
                    id: row["id"],
                    meetingID: row["meeting_id"],
                    path: row["path"],
                    model: row["model"],
                    promptHash: row["prompt_hash"],
                    createdAt: row["created_at"],
                    note: row["note"]
                )
            }
            return nil
        }
    }

    public func allSummaryVersions(meetingID: MeetingID) throws -> [SummaryVersion] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM summary_versions WHERE meeting_id = ? ORDER BY created_at ASC", arguments: [meetingID.raw])
            return rows.map { row in
                SummaryVersion(
                    id: row["id"],
                    meetingID: row["meeting_id"],
                    path: row["path"],
                    model: row["model"],
                    promptHash: row["prompt_hash"],
                    createdAt: row["created_at"],
                    note: row["note"]
                )
            }
        }
    }
}
