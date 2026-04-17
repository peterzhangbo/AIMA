import Foundation
import CryptoKit

public enum GemmaRunner {
    public static let model = "mlx-community/gemma-4-26b-a4b-it-4bit"

    /// 按 docs/01_environment_baseline.md 固定命令调用 mlx_vlm generate。
    /// max-tokens 保守设置（参考 docs/10 长会 OOM 教训）。
    public static func summarize(
        prompt: String,
        maxTokens: Int = 8192,
        logTo: URL? = nil
    ) throws -> String {
        let result = try ProcessRunner.run(
            executable: "python3",
            arguments: [
                "-m", "mlx_vlm", "generate",
                "--model", model,
                "--max-tokens", String(maxTokens),
                "--temperature", "0.0",
                "--prompt", prompt
            ],
            logTo: logTo
        )
        if !result.succeeded {
            throw ProcessRunnerError.nonZeroExit(code: result.exitCode, stderr: result.stderr)
        }
        return stripAssistantEcho(result.stdout, prompt: prompt)
    }

    public static func promptHash(_ prompt: String) -> String {
        let data = Data(prompt.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// mlx_vlm generate 输出处理。
    ///
    /// Gemma 4 会先输出思考链（`<channel>…</channel>` 块 + `<|turn|>/<|im_start|>` 等特殊 token），
    /// 再输出真正的回答，最后是 `==========` 分隔线和统计行。
    /// 处理顺序：
    ///   1. 剥离 `<channel>…</channel>` 思考块（含多行）
    ///   2. 剥离行级特殊 token (`<|…|>`, `Files:`, 纯空白)
    ///   3. 用 `==========` 分隔线截取生成区间
    ///   4. 剥离末尾统计行
    static func stripAssistantEcho(_ raw: String, prompt: String = "") -> String {
        var text = raw

        // ── 策略：在输出中定位「模型实际生成内容」的起点 ──────────────────
        // mlx_vlm Gemma 4 的输出格式：
        //   ==========
        //   Files: []
        //   Prompt: <bos><|turn>user\n<prompt>---<turn|>
        //   <|turn>model / <|channel>thought / <channel|>
        //   <实际内容>
        //   ==========
        //   Prompt: N tokens...  Generation: ...  Peak memory: ...
        //
        // 注意：prompt 末尾的 "---" 被 mlx_vlm 与 "<turn|>" 拼在同一行，
        // 导致精确匹配 prompt 失败。因此改用 turn 标记定位内容起点。

        // 1. 找最后一个 turn/channel 标记，取其后内容（涵盖思考链结束点）
        //    优先级：<channel|> > <|turn>model > <turn|>model > <|turn|> > <turn|>
        let turnMarkers = ["<channel|>", "<|turn>model", "<turn|>model",
                           "<|turn|>model", "<start_of_turn>model", "<|turn|>", "<turn|>"]
        var foundTurn = false
        for marker in turnMarkers {
            if let r = text.range(of: marker, options: .backwards) {
                text = String(text[r.upperBound...])
                foundTurn = true
                break
            }
        }

        // 2. 若没找到 turn 标记，则回退：找两条 "==========" 间的内容
        if !foundTurn {
            let parts = text.components(separatedBy: "==========")
            if parts.count >= 3 {
                // 三段：before / content / after(stats)
                text = parts[1]
            } else if parts.count == 2 {
                // 一条分隔线：判断内容在前还是在后
                let before = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let after  = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                // 统计行特征
                let isStats: (String) -> Bool = { s in
                    s.hasPrefix("Prompt:") || s.hasPrefix("Generation:") || s.hasPrefix("Peak memory:")
                }
                let afterIsOnlyStats = after.split(separator: "\n")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .allSatisfy { isStats($0) }
                text = afterIsOnlyStats ? before : after
            }
        }

        // 3. 按行过滤：剥掉特殊 token 行和统计/文件行
        let tokenPrefixes = ["<|", "Files:", "Prompt:", "Generation:", "Peak memory:"]
        var lines = text.components(separatedBy: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if tokenPrefixes.contains(where: { t.hasPrefix($0) }) { return false }
            // 纯标签行（如 <channel>、</channel>、<channel|>、<end_of_turn>）
            if t.hasPrefix("<") && t.hasSuffix(">") && !t.contains(" ") { return false }
            return true
        }

        // 4. 剥头部空行 / `---`
        while let first = lines.first {
            let t = first.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t == "---" { lines.removeFirst() } else { break }
        }

        // 5. 剥末尾空行 / `---` / `==========` / 统计行
        let trailPrefixes = ["Prompt:", "Generation:", "Peak memory:", "=========="]
        while let last = lines.last {
            let t = last.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t == "---" || trailPrefixes.contains(where: { t.hasPrefix($0) }) {
                lines.removeLast()
            } else { break }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum SummaryPrompt {

    /// 构建 Gemma 纪要 prompt。
    /// - 若提供了 `speakerSegments`（多人稿），则以 `[SPEAKER_XX] text` 格式生成逐字稿正文；
    /// - 否则回退到 Whisper 单人逐字稿。
    public static func build(
        transcript: Transcript,
        speakerSegments: [SpeakerSegment]? = nil,
        title: String? = nil
    ) -> String {
        let head: String
        if let t = title, !t.isEmpty {
            head = "会议主题：\(t)\n\n"
        } else {
            head = ""
        }

        let body: String
        if let segs = speakerSegments, !segs.isEmpty {
            // 多人稿：带说话人标签
            body = segs.map { seg in
                let tc = String(format: "[%02d:%02d]", Int(seg.start) / 60, Int(seg.start) % 60)
                return "\(tc) [\(seg.speaker)] \(seg.text)"
            }.joined(separator: "\n")
        } else if !transcript.segments.isEmpty {
            body = transcript.segments.map { seg in
                String(format: "[%02d:%02d] %@", Int(seg.start) / 60, Int(seg.start) % 60, seg.text)
            }.joined(separator: "\n")
        } else {
            body = transcript.text
        }

        let speakerNote = (speakerSegments != nil && !(speakerSegments?.isEmpty ?? true))
            ? "\n- 逐字稿中 [SPEAKER_XX] 为说话人编号，请在纪要中保留或根据上下文替换为实际角色。"
            : ""

        return """
        \(head)以下是一段会议的逐字稿，请用中文生成结构化的会议纪要，必须使用 Markdown 格式，包含如下分节：

        1. **会议概述**（2-3 句话总结背景与目标）
        2. **关键决策**（列出达成的一致意见）
        3. **讨论要点**（分话题整理关键观点，可按说话人区分）
        4. **行动项**（每条 `- [ ] 任务描述（负责人｜截止时间）` 形式；若无法判断负责人或时间，写"待定"）
        5. **待跟进问题**（尚未有结论的议题）

        要求：
        - 忠实于逐字稿，不捏造信息。
        - 使用原文中的人名/项目名。
        - 若逐字稿信息不足以填充某节，可写"（无）"。\(speakerNote)

        逐字稿：
        ---
        \(body)
        ---
        """
    }
}
