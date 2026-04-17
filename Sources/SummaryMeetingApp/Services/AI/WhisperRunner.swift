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

    // MARK: - 公共入口

    /// 智能转写：短于 1.2× chunkDuration 直接转写，更长则自动分段。
    /// 调用方统一用此方法，无需关心内部是否分段。
    public static func transcribe(
        audio: URL,
        outputDir: URL,
        chunkDuration: TimeInterval = AudioChunker.defaultChunkDuration,
        logTo: URL? = nil
    ) throws -> Transcript {
        let totalDuration = (try? AudioChunker.duration(of: audio, logTo: logTo)) ?? 0
        if totalDuration <= chunkDuration * 1.2 {
            return try transcribeSingle(audio: audio, outputDir: outputDir, initialPrompt: "", logTo: logTo)
        }
        return try transcribeChunked(audio: audio, outputDir: outputDir,
                                     chunkDuration: chunkDuration, logTo: logTo)
    }

    // MARK: - 分段转写

    /// 将长音频切片后逐段转写，合并时自动补偿时间戳偏移。
    /// 上一段末尾作为下一段的 --initial-prompt，保持上下文连贯。
    public static func transcribeChunked(
        audio: URL,
        outputDir: URL,
        chunkDuration: TimeInterval = AudioChunker.defaultChunkDuration,
        logTo: URL? = nil
    ) throws -> Transcript {
        let chunksDir = outputDir.appendingPathComponent("chunks", isDirectory: true)
        let chunks = try AudioChunker.split(
            audio: audio,
            chunkDuration: chunkDuration,
            outputDir: chunksDir,
            logTo: logTo
        )

        var allSegments: [TranscriptSegment] = []
        var texts: [String] = []
        var language: String? = nil
        var previousText = ""

        for chunk in chunks {
            let chunkDir = outputDir
                .appendingPathComponent(String(format: "chunk_%03d", chunk.index), isDirectory: true)
            let ct = try transcribeSingle(
                audio: chunk.url,
                outputDir: chunkDir,
                initialPrompt: previousText,
                logTo: logTo
            )

            if language == nil { language = ct.language }
            texts.append(ct.text)
            previousText = String(ct.text.suffix(100))  // 末尾 100 字符作上下文

            let idOffset = allSegments.count
            let adjusted = ct.segments.map { seg in
                TranscriptSegment(
                    id: idOffset + seg.id,
                    start: seg.start + chunk.startOffset,
                    end: seg.end + chunk.startOffset,
                    text: seg.text
                )
            }
            allSegments.append(contentsOf: adjusted)
        }

        return Transcript(
            language: language,
            text: texts.joined(separator: " "),
            segments: allSegments
        )
    }

    // MARK: - 单文件转写（内部）

    static func transcribeSingle(
        audio: URL,
        outputDir: URL,
        initialPrompt: String,
        logTo: URL? = nil
    ) throws -> Transcript {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var args = [
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
        ]
        if !initialPrompt.isEmpty {
            args += ["--initial-prompt", initialPrompt]
        }

        let result = try ProcessRunner.run(executable: "mlx_whisper", arguments: args, logTo: logTo)
        if !result.succeeded {
            throw ProcessRunnerError.nonZeroExit(code: result.exitCode, stderr: result.stderr)
        }

        let jsonPath = outputDir.appendingPathComponent(
            audio.deletingPathExtension().lastPathComponent + ".json"
        )
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
