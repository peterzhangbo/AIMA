import Foundation
import GRDB

// MARK: - 任务模型

public struct ProcessingTask: Sendable, Equatable {
    public enum State: String, Sendable, Codable {
        case running
        case completed
        case failed
    }

    public var meetingID: MeetingID
    public var stage: ProcessingStage
    public var state: State
    public var attempts: Int
    public var lastError: String?
    public var updatedAt: Date

    public init(meetingID: MeetingID, stage: ProcessingStage) {
        self.meetingID = meetingID
        self.stage     = stage
        self.state     = .running
        self.attempts  = 1
        self.lastError = nil
        self.updatedAt = Date()
    }
}

// MARK: - TaskQueue

/// 轻量任务队列：将处理阶段持久化到 SQLite，App 重启后能看到未完成的任务。
/// 恢复逻辑（重新执行）由 RecordingCoordinator 根据 pendingTasks() 决定。
@MainActor
public final class TaskQueue {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - 写

    /// 创建或覆盖任务记录（每个 meeting 只保留一条）
    public func upsert(_ task: ProcessingTask) {
        try? dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (meeting_id, stage, state, attempts, last_error, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(meeting_id) DO UPDATE SET
                    stage=excluded.stage,
                    state=excluded.state,
                    attempts=excluded.attempts,
                    last_error=excluded.last_error,
                    updated_at=excluded.updated_at
                """,
                arguments: [
                    task.meetingID.raw,
                    task.stage.rawValue,
                    task.state.rawValue,
                    task.attempts,
                    task.lastError,
                    task.updatedAt
                ])
        }
    }

    public func markCompleted(meetingID: MeetingID) {
        try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE tasks SET state='completed', updated_at=? WHERE meeting_id=?",
                arguments: [Date(), meetingID.raw]
            )
        }
    }

    public func markFailed(meetingID: MeetingID, error: String) {
        try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE tasks SET state='failed', last_error=?, updated_at=? WHERE meeting_id=?",
                arguments: [error, Date(), meetingID.raw]
            )
        }
    }

    public func updateStage(meetingID: MeetingID, stage: ProcessingStage) {
        try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE tasks SET stage=?, updated_at=? WHERE meeting_id=?",
                arguments: [stage.rawValue, Date(), meetingID.raw]
            )
        }
    }

    // MARK: - 读

    /// App 启动时查询 running 状态的任务（可能是上次崩溃遗留的）
    public func pendingTasks() -> [ProcessingTask] {
        (try? dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM tasks WHERE state='running' ORDER BY updated_at DESC"
            )
            return rows.compactMap { Self.rowToTask($0) }
        }) ?? []
    }

    public func task(for meetingID: MeetingID) -> ProcessingTask? {
        try? dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM tasks WHERE meeting_id=?",
                arguments: [meetingID.raw]
            ) else { return nil }
            return Self.rowToTask(row)
        }
    }

    // MARK: - Private

    private static func rowToTask(_ row: Row) -> ProcessingTask? {
        guard
            let mid = row["meeting_id"] as? String,
            let stageRaw = row["stage"] as? String,
            let stage = ProcessingStage(rawValue: stageRaw),
            let stateRaw = row["state"] as? String,
            let state = ProcessingTask.State(rawValue: stateRaw)
        else { return nil }

        var t = ProcessingTask(meetingID: MeetingID(mid), stage: stage)
        t.state     = state
        t.attempts  = (row["attempts"] as? Int) ?? 1
        t.lastError = row["last_error"] as? String
        t.updatedAt = (row["updated_at"] as? Date) ?? Date()
        return t
    }
}
