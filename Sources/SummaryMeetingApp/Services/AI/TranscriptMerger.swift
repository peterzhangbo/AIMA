import Foundation

// MARK: - 多人逐字稿数据模型

/// 一条带说话人标签的逐字稿段落
public struct SpeakerSegment: Identifiable, Codable, Sendable, Equatable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var speaker: String   // 例如 "SPEAKER_00"
    public var text: String

    public init(id: Int, start: Double, end: Double, speaker: String, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

// MARK: - 合并器

/// Segment-level 合并 Whisper 转写与 pyannote 分离结果。
///
/// 不做 word-level 对齐（参考 docs/07 教训），降低复杂度与错误风险。
/// 只做 segment-level：为每个 Whisper segment 找最大时间重叠的说话人。
public enum TranscriptMerger {

    // MARK: Public API

    /// **raw**：每个 Whisper segment 独立标注说话人，相邻同人段不合并。
    /// 适合调试和存档。
    public static func mergeRaw(
        transcript: Transcript,
        diarization: [DiarizeSegment]
    ) -> [SpeakerSegment] {
        transcript.segments.enumerated().map { i, seg in
            let speaker = assignSpeaker(to: seg, using: diarization)
            return SpeakerSegment(
                id: i,
                start: seg.start,
                end: seg.end,
                speaker: speaker,
                text: seg.text
            )
        }
    }

    /// **clean**：在 raw 基础上合并相邻同一说话人的段（间隔 < 2 秒），
    /// 产出更自然的段落划分，供纪要 Prompt 和 UI 展示使用。
    public static func mergeClean(raw: [SpeakerSegment]) -> [SpeakerSegment] {
        var result: [SpeakerSegment] = []
        for seg in raw {
            if var last = result.last,
               last.speaker == seg.speaker,
               seg.start - last.end < 2.0 {
                last.end  = seg.end
                last.text = last.text + " " + seg.text
                result[result.count - 1] = last
            } else {
                result.append(SpeakerSegment(
                    id: result.count,
                    start: seg.start,
                    end: seg.end,
                    speaker: seg.speaker,
                    text: seg.text
                ))
            }
        }
        return result
    }

    // MARK: - Serialize

    /// 序列化为 JSON 并落盘
    public static func save(_ segments: [SpeakerSegment], to url: URL) throws {
        let data = try JSONEncoder().encode(segments)
        try data.write(to: url, options: .atomic)
    }

    /// 从 JSON 文件加载
    public static func load(from url: URL) throws -> [SpeakerSegment] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([SpeakerSegment].self, from: data)
    }

    // MARK: - Private

    /// 为 Whisper segment 分配说话人：找与之时间重叠最多的 diarize segment。
    /// 若最大重叠不足 segment 时长的 10%，标记为 "SPEAKER_UNKNOWN"。
    private static func assignSpeaker(
        to seg: TranscriptSegment,
        using diarization: [DiarizeSegment]
    ) -> String {
        let segDuration = max(seg.end - seg.start, 0.01)
        var bestSpeaker = "SPEAKER_UNKNOWN"
        var bestOverlap: Double = 0

        for d in diarization {
            let overlap = min(seg.end, d.end) - max(seg.start, d.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeaker = d.speaker
            }
        }
        return bestOverlap >= segDuration * 0.1 ? bestSpeaker : "SPEAKER_UNKNOWN"
    }
}
