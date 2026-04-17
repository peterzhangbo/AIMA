import Foundation

public struct TranscriptSegment: Identifiable, Sendable, Codable, Equatable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var text: String
}

public struct Transcript: Sendable, Codable, Equatable {
    public var language: String?
    public var text: String
    public var segments: [TranscriptSegment]
}

public enum WhisperRunner {
    /// 按 docs/01_environment_baseline.md 固定命令调用 mlx_whisper。
    public static func transcribe(
        audio: URL,
        outputDir: URL,
        logTo: URL? = nil
    ) throws -> Transcript {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let result = try ProcessRunner.run(
            executable: "mlx_whisper",
            arguments: [
                audio.path,
                "--model", "mlx-community/whisper-large-v3-turbo",
                "--language", "zh",
                "--word-timestamps", "True",
                "--temperature", "0",
                "--condition-on-previous-text", "True",
                "--hallucination-silence-threshold", "0.6",
                "--max-words-per-line", "20",
                "--max-line-count", "2",
                "-f", "json",
                "-o", outputDir.path
            ],
            logTo: logTo
        )
        if !result.succeeded {
            throw ProcessRunnerError.nonZeroExit(code: result.exitCode, stderr: result.stderr)
        }

        let jsonPath = outputDir.appendingPathComponent(audio.deletingPathExtension().lastPathComponent + ".json")
        return try parseTranscript(jsonURL: jsonPath)
    }

    /// 容忍 NaN 的解析（参考 docs/05）。
    public static func parseTranscript(jsonURL: URL) throws -> Transcript {
        let raw = try String(contentsOf: jsonURL, encoding: .utf8)
        let sanitized = raw
            .replacingOccurrences(of: ": NaN", with: ": null")
            .replacingOccurrences(of: ":NaN", with: ":null")
            .replacingOccurrences(of: ": -Infinity", with: ": null")
            .replacingOccurrences(of: ": Infinity", with: ": null")
        guard let data = sanitized.data(using: .utf8) else {
            throw NSError(domain: "WhisperRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法编码 json"])
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "WhisperRunner", code: 2, userInfo: [NSLocalizedDescriptionKey: "transcript json 非对象"])
        }

        let language = obj["language"] as? String
        let fullText = (obj["text"] as? String) ?? ""
        var segments: [TranscriptSegment] = []
        if let raw = obj["segments"] as? [[String: Any]] {
            for (i, seg) in raw.enumerated() {
                let start = (seg["start"] as? Double) ?? 0
                let end = (seg["end"] as? Double) ?? start
                let text = (seg["text"] as? String) ?? ""
                segments.append(TranscriptSegment(id: i, start: start, end: end, text: text.trimmingCharacters(in: .whitespaces)))
            }
        }
        return Transcript(language: language, text: fullText, segments: segments)
    }
}
