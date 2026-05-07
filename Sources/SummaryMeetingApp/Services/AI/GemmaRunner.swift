import Foundation
import CryptoKit

public enum GemmaRunner {
    /// 按硬件档位（RAM）选模型。和 PermissionsModel.recommendedGemma 必须保持同步：
    /// 安装命令、检测、运行时三处都用同一档对应的 ID。
    /// - <16GB:  gemma-4-e4b-it-4bit (~3GB)
    /// - 16-32GB: gemma-4-26b-a4b-it-4bit (~15-18GB)
    /// - ≥32GB:  gemma-4-31b-it-4bit (~18-22GB)
    public static var model: String {
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if ramGB >= 32 { return "mlx-community/gemma-4-31b-it-4bit" }
        if ramGB >= 16 { return "mlx-community/gemma-4-26b-a4b-it-4bit" }
        return "mlx-community/gemma-4-e4b-it-4bit"
    }

    /// 按 docs/01_environment_baseline.md 固定命令调用 mlx_vlm generate。
    /// max-tokens 保守设置（参考 docs/10 长会 OOM 教训）。
    /// 智能纪要：短稿直接生成，长稿（>120段 或 >8000字）自动分段摘要 + 二次汇总。
    public static func summarizeSmart(
        transcript: Transcript,
        speakerSegments: [SpeakerSegment]? = nil,
        segmentsPerChunk: Int = 120,
        logTo: URL? = nil
    ) throws -> String {
        let segCount = speakerSegments?.count ?? transcript.segments.count
        let charCount = (speakerSegments?.map(\.text).joined() ?? transcript.text).count

        // 短稿直接走单次
        if segCount <= segmentsPerChunk && charCount <= 8_000 {
            return try summarize(
                prompt: SummaryPrompt.build(transcript: transcript, speakerSegments: speakerSegments),
                logTo: logTo
            )
        }

        // 分段纪要
        let chunkSize = segmentsPerChunk
        var partSummaries: [String] = []

        if let spk = speakerSegments, !spk.isEmpty {
            let chunks = stride(from: 0, to: spk.count, by: chunkSize).map {
                Array(spk[$0 ..< min($0 + chunkSize, spk.count)])
            }
            for (i, chunk) in chunks.enumerated() {
                let prompt = SummaryPrompt.buildPart(
                    speakerSegments: chunk, partIndex: i + 1, totalParts: chunks.count
                )
                let partial = try summarize(prompt: prompt, maxTokens: 3000, logTo: logTo)
                partSummaries.append(partial)
            }
        } else {
            let segsFlat = transcript.segments
            let chunks = stride(from: 0, to: segsFlat.count, by: chunkSize).map {
                Array(segsFlat[$0 ..< min($0 + chunkSize, segsFlat.count)])
            }
            for (i, chunk) in chunks.enumerated() {
                let subTranscript = Transcript(language: transcript.language,
                                               text: chunk.map(\.text).joined(separator: " "),
                                               segments: chunk)
                let prompt = SummaryPrompt.buildPart(
                    transcript: subTranscript, partIndex: i + 1, totalParts: chunks.count
                )
                let partial = try summarize(prompt: prompt, maxTokens: 3000, logTo: logTo)
                partSummaries.append(partial)
            }
        }

        // 二次汇总
        let mergePrompt = SummaryPrompt.buildMerge(partSummaries: partSummaries)
        return try summarize(prompt: mergePrompt, maxTokens: 6000, logTo: logTo)
    }

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

    /// 检查纪要 Markdown 是否覆盖了 prompt 模板要求的全部 7 个二级标题。
    /// 返回缺失的标题列表（空则完整）。给 pipeline 层做"提示偏漂"告警用。
    public static func missingSectionHeaders(_ markdown: String) -> [String] {
        let required = [
            "会议标题", "会议概述", "会议总结",
            "关键决策", "讨论要点", "待办事项", "风险和未决问题"
        ]
        return required.filter { name in
            !markdown.contains("## \(name)")
        }
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

        var cleaned = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // 6. 裁掉第一个行首 `## ` 之前的任何前言（例如"根据您的要求，以下是…"）
        //    模板要求纪要第一行是 `## 会议标题`，所以任何 `## ` 之前的文本都是多余前言。
        if cleaned.contains("## ") {
            let parts = cleaned.components(separatedBy: "\n")
            if let firstHeaderIdx = parts.firstIndex(where: { $0.hasPrefix("## ") }) {
                cleaned = parts[firstHeaderIdx...].joined(separator: "\n")
            }
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
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
        \(head)以下是一段会议的逐字稿（每行前 `[mm:ss]` 为该段话在会议中的起始时间戳），请用中文生成结构化的会议纪要。

        严格按照以下 Markdown 模板输出，**模板中的二级标题（## 开头）是字面量，不得修改、翻译或合并，不得增加额外标题**。直接输出纪要正文，**不要有任何前言（例如"根据您的要求…""以下是…"）或结语**，第一行必须是 `## 会议标题`。

        模板（严格按此结构，按此顺序，保留所有标题）：

        ```
        ## 会议标题
        <≤15 个汉字的短语，不含"会议""讨论""纪要"等冗词，不加引号/句号>

        ## 会议概述
        <2-3 句话总结背景与目标>

        ## 会议总结
        <150-200 字自然段，覆盖主要结论与走向>

        ## 关键决策
        - [mm:ss] 决策内容
        - [mm:ss] 决策内容

        ## 讨论要点
        ### 话题名
        - [mm:ss] **[说话人]** 该发言的核心内容（可含关键数据/论据/观点）
        - [mm:ss] **[说话人]** 核心内容
        ### 话题名
        - [mm:ss] **[说话人]** 核心内容

        ## 待办事项
        | 事项 | 负责人 | 截止时间 | 备注 |
        | --- | --- | --- | --- |
        | ... | ... | ... | ... |

        ## 风险和未决问题
        - [mm:ss] 风险/未决点 — 影响或所需决策
        ```

        要求：
        - 必须输出所有 7 个 `## ` 二级标题，**原样照抄**（会议标题 / 会议概述 / 会议总结 / 关键决策 / 讨论要点 / 待办事项 / 风险和未决问题）。
        - **讨论要点**须按话题分 `### 小节`，每条条目必须以 `[mm:ss] **[说话人]**` 开头，记录该人在该话题下的具体发言内容；**同一话题多人发言分别列条，同一人在同一话题下的多次发言按时间顺序分别列条**。
        - 记录粒度：**任何一段同一人连续发言超过 100 字必须单独列条**；连续发言不足 100 字但涉及决策、数据、论据、反对意见、关键结论等重要内容的，也必须列条；只有寒暄/确认/重复无内容的发言可省略。
        - 每条内容应尽量保留原话要点（可略作压缩），不得只写一句模糊概括。
        - 时间戳必须使用逐字稿里出现过的 `[mm:ss]`，不得编造。
        - 忠实于逐字稿，不捏造信息；使用原文中的人名/项目名。
        - 某节信息不足时，该节内容写"（无）"但仍保留 `## ` 小节标题。
        - 待办事项必须是 Markdown 表格，表头严格为 `| 事项 | 负责人 | 截止时间 | 备注 |`，未知字段填"待定"。\(speakerNote)

        逐字稿：
        ---
        \(body)
        ---
        """
    }

    // MARK: - 分段 prompt（长会用）

    /// 对长会的某一分段生成局部摘要（不要求完整五节，只提炼要点）
    public static func buildPart(
        transcript: Transcript? = nil,
        speakerSegments: [SpeakerSegment]? = nil,
        partIndex: Int,
        totalParts: Int
    ) -> String {
        let body: String
        if let segs = speakerSegments, !segs.isEmpty {
            body = segs.map { seg in
                let tc = String(format: "[%02d:%02d]", Int(seg.start) / 60, Int(seg.start) % 60)
                return "\(tc) [\(seg.speaker)] \(seg.text)"
            }.joined(separator: "\n")
        } else if let t = transcript {
            body = t.segments.isEmpty ? t.text :
                t.segments.map { seg in
                    String(format: "[%02d:%02d] %@", Int(seg.start) / 60, Int(seg.start) % 60, seg.text)
                }.joined(separator: "\n")
        } else {
            body = ""
        }
        return """
        这是一场长会的第 \(partIndex)/\(totalParts) 段逐字稿（每行前 `[mm:ss]` 为该段话起始时间戳）。
        请用中文提炼：关键决策、讨论要点（按话题分小节；每条以 `[mm:ss] **[说话人]** 内容` 开头，记录该人在该话题下的具体发言；同一人连续发言超过100字必须单独列条，不足100字但涉及决策/数据/论据/反对/关键结论的也必须列条）、待办事项、风险和未决问题。
        所有提取条目必须保留 `[mm:ss]` 时间戳；不要捏造。

        逐字稿片段：
        ---
        \(body)
        ---
        """
    }

    /// 将多段局部摘要二次合并为标准五节格式纪要
    public static func buildMerge(partSummaries: [String]) -> String {
        let combined = partSummaries.enumerated().map { i, s in
            "### 第 \(i + 1) 段摘要\n\(s)"
        }.joined(separator: "\n\n")
        return """
        以下是一场长会按时间顺序拆分的 \(partSummaries.count) 段局部摘要。请整合为一份完整的中文会议纪要。

        严格按照以下 Markdown 模板输出，**模板中的二级标题（## 开头）是字面量，不得修改、翻译或合并**。直接输出纪要正文，**不要有任何前言（例如"根据您的要求…""以下是…"）或结语**，第一行必须是 `## 会议标题`。

        模板（严格按此结构，按此顺序，保留所有标题）：

        ```
        ## 会议标题
        <≤15 个汉字的短语>

        ## 会议概述
        <2-3 句话>

        ## 会议总结
        <150-200 字自然段>

        ## 关键决策
        - [mm:ss] 决策内容

        ## 讨论要点
        ### 话题名
        - [mm:ss] **[说话人]** 该发言的核心内容
        - [mm:ss] **[说话人]** 核心内容
        ### 话题名
        - [mm:ss] **[说话人]** 核心内容

        ## 待办事项
        | 事项 | 负责人 | 截止时间 | 备注 |
        | --- | --- | --- | --- |
        | ... | ... | ... | ... |

        ## 风险和未决问题
        - [mm:ss] 风险/未决点 — 影响或所需决策
        ```

        要求：
        - 必须输出所有 7 个 `## ` 二级标题，**原样照抄**。
        - **讨论要点**按话题分 `### 小节`，每条以 `[mm:ss] **[说话人]**` 开头；保留各分段摘要里同一人超过100字的完整发言和不足100字但重要（决策/数据/论据/反对/关键结论）的发言；不同话题不要合并。
        - 去重合并字面相近的重复条目；保留原文人名/项目名；时间戳必须来自原逐字稿，不要编造。
        - 某节信息不足时，该节内容写"（无）"但仍保留 `## ` 小节标题。
        - 待办事项必须是 Markdown 表格，表头严格为 `| 事项 | 负责人 | 截止时间 | 备注 |`。

        ---
        \(combined)
        ---
        """
    }
}
