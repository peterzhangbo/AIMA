import Foundation

// MARK: - 数据模型

/// pyannote 输出的单条说话人片段（原始时间轴对齐）
public struct DiarizeSegment: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var speaker: String
}

// MARK: - 错误类型

public enum DiarizeError: Error, LocalizedError {
    case scriptNotFound(String)
    case nonZeroExit(code: Int32, stderr: String)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .scriptNotFound(let p):
            return "diarize.py 未找到: \(p)"
        case .nonZeroExit(let c, let e):
            return "pyannote 退出码 \(c)：\(e.prefix(300))"
        case .parseError(let m):
            return "解析 diarize JSON 失败: \(m)"
        }
    }
}

// MARK: - Runner

public enum DiarizeRunner {

    /// 调用 `scripts/diarize.py` 对音频进行说话人分离。
    /// - Parameters:
    ///   - audio: 输入音频文件（wav/m4a 均可）
    ///   - outputDir: 产物目录，`diarize.json` 将落盘到此处
    ///   - hfToken: Hugging Face token；nil 时自动读取 ~/.hf_token
    ///   - logTo: 日志落盘路径（可选）
    /// - Returns: 说话人片段数组
    public static func diarize(
        audio: URL,
        outputDir: URL,
        hfToken: String? = nil,
        logTo: URL? = nil
    ) throws -> [DiarizeSegment] {
        let scriptURL = scriptsDir().appendingPathComponent("diarize.py")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw DiarizeError.scriptNotFound(scriptURL.path)
        }

        var env: [String: String] = [:]
        if let token = hfToken ?? readHFToken() {
            env["HF_TOKEN"] = token
        }

        let result = try ProcessRunner.run(
            executable: "python3",
            arguments: [scriptURL.path, audio.path],
            extraEnvironment: env,
            logTo: logTo
        )

        if !result.succeeded {
            throw DiarizeError.nonZeroExit(code: result.exitCode, stderr: result.stderr)
        }

        // 落盘 JSON
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let jsonURL = outputDir.appendingPathComponent("diarize.json")
        try result.stdout.write(to: jsonURL, atomically: true, encoding: .utf8)

        // 解析
        guard let data = result.stdout.data(using: .utf8) else {
            throw DiarizeError.parseError("stdout 编码失败")
        }
        do {
            return try JSONDecoder().decode([DiarizeSegment].self, from: data)
        } catch {
            throw DiarizeError.parseError(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    /// 读取本机存储的 HF token（~/.hf_token 或 ~/.huggingface/token）
    public static func readHFToken() -> String? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let candidates = [
            home.appendingPathComponent(".hf_token").path,
            home.appendingPathComponent(".huggingface/token").path,
        ]
        for path in candidates {
            if let t = try? String(contentsOfFile: path, encoding: .utf8) {
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// 定位 `scripts/` 目录，按优先级依次尝试三个位置：
    ///
    /// 1. `.app` bundle — `Contents/Resources/scripts/`（build_app.sh 复制进去）
    /// 2. `swift run` 开发构建 — 可执行文件上溯两级到仓库根（`.build/debug/exe` → repo）
    /// 3. `#file` 编译期路径 — 源码树内最终兜底
    private static func scriptsDir() -> URL {
        let needle = "diarize.py"
        let fm = FileManager.default

        // 1. .app bundle: Contents/Resources/scripts/
        if let resURL = Bundle.main.resourceURL {
            let candidate = resURL.appendingPathComponent("scripts")
            if fm.fileExists(atPath: candidate.appendingPathComponent(needle).path) {
                return candidate
            }
        }

        // 2. swift run: 可执行文件在 .build/debug/，再上溯两层到仓库根
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let devCandidate = execURL
            .deletingLastPathComponent()  // debug/ 或 release/
            .deletingLastPathComponent()  // .build/
            .appendingPathComponent("scripts")
        if fm.fileExists(atPath: devCandidate.appendingPathComponent(needle).path) {
            return devCandidate
        }

        // 3. #file 编译期路径（源码树内兜底）
        //    DiarizeRunner.swift → AI/ → Services/ → SummaryMeetingApp/ → Sources/ → repo root
        let compileFallback = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // AI/
            .deletingLastPathComponent()  // Services/
            .deletingLastPathComponent()  // SummaryMeetingApp/
            .deletingLastPathComponent()  // Sources/
            .appendingPathComponent("scripts")
        return compileFallback
    }
}
