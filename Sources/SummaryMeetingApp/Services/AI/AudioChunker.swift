import Foundation

// MARK: - 数据模型

public struct AudioChunk: Sendable {
    public let url: URL
    public let startOffset: TimeInterval   // 在原始音频中的起始秒数
    public let index: Int
}

// MARK: - 错误

public enum AudioChunkerError: Error, LocalizedError {
    case ffprobeFailed(String)
    case parseDurationFailed(String)
    case ffmpegFailed(String)
    case noChunksProduced

    public var errorDescription: String? {
        switch self {
        case .ffprobeFailed(let e):     return "ffprobe 失败: \(e.prefix(200))"
        case .parseDurationFailed(let s): return "无法解析时长: \(s)"
        case .ffmpegFailed(let e):      return "ffmpeg 分段失败: \(e.prefix(200))"
        case .noChunksProduced:         return "ffmpeg 未产出任何 chunk 文件"
        }
    }
}

// MARK: - AudioChunker

public enum AudioChunker {
    /// 默认分段时长（秒）
    public static let defaultChunkDuration: TimeInterval = 600   // 10 分钟

    // MARK: - 时长探测

    /// 使用 ffprobe 获取音频总时长（秒）
    public static func duration(of audio: URL, logTo: URL? = nil) throws -> TimeInterval {
        let result = try ProcessRunner.run(
            executable: "ffprobe",
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                audio.path
            ],
            logTo: logTo
        )
        if !result.succeeded {
            throw AudioChunkerError.ffprobeFailed(result.stderr)
        }
        let str = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dur = Double(str), dur.isFinite, dur > 0 else {
            throw AudioChunkerError.parseDurationFailed(str)
        }
        return dur
    }

    // MARK: - 切片

    /// 使用 ffmpeg segment 切片，返回有序 chunk 列表。
    ///
    /// 输出格式：16kHz 单声道 WAV（Whisper 最优格式）。
    /// 实际 chunk 时长可能略短（最后一片），`startOffset` 按标称值估算。
    public static func split(
        audio: URL,
        chunkDuration: TimeInterval = defaultChunkDuration,
        outputDir: URL,
        logTo: URL? = nil
    ) throws -> [AudioChunk] {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let pattern = outputDir.appendingPathComponent("chunk_%03d.wav").path
        let result = try ProcessRunner.run(
            executable: "ffmpeg",
            arguments: [
                "-y", "-i", audio.path,
                "-f", "segment",
                "-segment_time", String(Int(chunkDuration)),
                "-ar", "16000",
                "-ac", "1",
                pattern
            ],
            logTo: logTo
        )
        if !result.succeeded {
            throw AudioChunkerError.ffmpegFailed(result.stderr)
        }

        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: [.nameKey])) ?? []
        let chunks: [AudioChunk] = files
            .filter { $0.lastPathComponent.hasPrefix("chunk_") && $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .enumerated()
            .map { idx, url in
                AudioChunk(url: url, startOffset: Double(idx) * chunkDuration, index: idx)
            }

        if chunks.isEmpty { throw AudioChunkerError.noChunksProduced }
        return chunks
    }
}
