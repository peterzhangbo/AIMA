import Foundation

public struct MeetingID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public static func new() -> MeetingID {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let suffix = String(UUID().uuidString.prefix(6))
        return MeetingID("\(stamp)-\(suffix)")
    }
    public var description: String { raw }
}

public enum RecordingState: Equatable, Sendable {
    case idle
    case preparing
    case recording(startedAt: Date)
    case paused(totalElapsed: TimeInterval)
    case stopping
    case failed(message: String)
}

public enum ProcessingStage: String, Sendable, Codable {
    case savingAudio
    case transcribing
    case diarizing      // 说话人分离（可降级）
    case parsingTranscript
    case summarizing
    case completed
    case failed
}

public enum MeetingStatus: String, Sendable, Codable {
    case recording
    case queued      // 已停止录制，等待后台流水线
    case processing
    case completed
    case failed
}

public struct Meeting: Identifiable, Sendable, Equatable {
    public let id: MeetingID
    public var title: String
    public var createdAt: Date
    public var durationMs: Int
    public var status: MeetingStatus
    public var audioPath: String?
    public var failureReason: String?

    public init(
        id: MeetingID,
        title: String,
        createdAt: Date,
        durationMs: Int = 0,
        status: MeetingStatus,
        audioPath: String? = nil,
        failureReason: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.durationMs = durationMs
        self.status = status
        self.audioPath = audioPath
        self.failureReason = failureReason
    }
}
