import Foundation
import Observation

@MainActor
@Observable
public final class RecordingCoordinator {
    public private(set) var state: RecordingState = .idle
    public private(set) var currentMeetingID: MeetingID?
    public private(set) var currentPaths: SessionPaths?
    public private(set) var processingStage: ProcessingStage?
    public private(set) var lastTranscript: Transcript?
    public private(set) var lastSpeakerSegments: [SpeakerSegment]?   // nil = 分离未运行或已降级
    public private(set) var lastSummaryMarkdown: String?
    public private(set) var lastError: String?
    public private(set) var lastCompletedMeetingID: MeetingID?

    private let store: MeetingStore
    private let taskQueue: TaskQueue
    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private var startedAt: Date?
    private var pausedAccumulated: TimeInterval = 0
    private var resumedAt: Date?
    private var systemAudioDegraded = false

    public init(store: MeetingStore) {
        self.store = store
        self.taskQueue = TaskQueue(dbQueue: store.dbQueue)
    }

    public func start() async {
        // 允许从 idle 或上一次 failed 重新开始
        switch state {
        case .idle, .failed: break
        default: return
        }
        self.lastError = nil
        self.lastTranscript = nil
        self.lastSpeakerSegments = nil
        self.lastSummaryMarkdown = nil
        self.processingStage = nil
        self.systemAudioDegraded = false
        self.state = .preparing

        let id = MeetingID.new()
        let paths = SessionPaths(root: SessionPaths.defaultRoot(), meetingID: id)
        do {
            try paths.ensureCreated()
        } catch {
            self.state = .failed(message: "会议目录创建失败: \(error.localizedDescription)")
            return
        }
        self.currentMeetingID = id
        self.currentPaths = paths

        let initial = Meeting(
            id: id,
            title: defaultTitle(for: Date()),
            createdAt: Date(),
            status: .recording
        )
        try? store.upsert(initial)

        do {
            try mic.start(to: paths.micWav)
        } catch {
            let reason = "麦克风启动失败: \(error.localizedDescription)"
            self.state = .failed(message: reason)
            // 把刚插入的 recording 行标记为 failed，避免历史侧栏出现永久"录制中"幽灵行
            markFailed(meetingID: id, reason: reason)
            return
        }

        do {
            try await system.start(to: paths.systemAudio)
        } catch {
            systemAudioDegraded = true
        }

        let now = Date()
        self.startedAt = now
        self.resumedAt = now
        self.pausedAccumulated = 0
        self.state = .recording(startedAt: now)
    }

    public func pause() {
        guard case .recording = state else { return }
        mic.pause()
        system.pause()   // 同时暂停系统音频，避免暂停期间对端声音混入录制
        if let resumedAt = resumedAt {
            pausedAccumulated += Date().timeIntervalSince(resumedAt)
        }
        self.resumedAt = nil
        self.state = .paused(totalElapsed: pausedAccumulated)
    }

    public func resume() {
        guard case .paused = state else { return }
        mic.resume()
        system.resume()  // 同步恢复系统音频
        self.resumedAt = Date()
        if let startedAt = startedAt {
            self.state = .recording(startedAt: startedAt)
        }
    }

    public func stopAndProcess() async {
        switch state {
        case .recording, .paused: break
        default: return
        }
        let elapsed = elapsedSeconds()
        self.state = .stopping
        mic.stop()
        await system.stop()
        self.processingStage = .savingAudio

        guard let paths = currentPaths, let meetingID = currentMeetingID else {
            self.state = .failed(message: "缺少会议目录")
            return
        }

        // 立即标记为 processing，历史侧栏可见 + 任务队列持久化
        if var m = try? store.meeting(id: meetingID) {
            m.status = .processing
            try? store.upsert(m)
        }
        taskQueue.upsert(ProcessingTask(meetingID: meetingID, stage: .savingAudio))

        // 混音
        do {
            try AudioMixer.mix(
                mic: FileManager.default.fileExists(atPath: paths.micWav.path) ? paths.micWav : nil,
                system: (!systemAudioDegraded && FileManager.default.fileExists(atPath: paths.systemAudio.path)) ? paths.systemAudio : nil,
                output: paths.mixedWav,
                logTo: paths.logFile
            )
        } catch {
            self.processingStage = .failed
            self.state = .failed(message: "混音失败: \(error.localizedDescription)")
            markFailed(meetingID: meetingID, reason: "混音失败: \(error.localizedDescription)")
            return
        }

        // Whisper 转写（自动分段）
        self.processingStage = .transcribing
        taskQueue.updateStage(meetingID: meetingID, stage: .transcribing)
        let transcript: Transcript
        do {
            transcript = try await Task.detached(priority: .userInitiated) {
                try WhisperRunner.transcribe(
                    audio: paths.mixedWav,
                    outputDir: paths.transcriptDir,
                    logTo: paths.logFile
                )
            }.value
        } catch {
            self.processingStage = .failed
            self.state = .failed(message: "转写失败: \(error.localizedDescription)")
            markFailed(meetingID: meetingID, reason: "转写失败: \(error.localizedDescription)")
            return
        }
        self.lastTranscript = transcript

        // 登记 Whisper raw transcript 版本
        let transcriptPath = paths.transcriptDir.appendingPathComponent("mixed.json")
        if FileManager.default.fileExists(atPath: transcriptPath.path) {
            _ = try? store.addTranscriptVersion(meetingID: meetingID, kind: "raw", path: transcriptPath)
        }

        // ── 说话人分离（可降级）────────────────────────────────────────────
        self.processingStage = .diarizing
        taskQueue.updateStage(meetingID: meetingID, stage: .diarizing)
        var speakerSegments: [SpeakerSegment]? = nil
        do {
            let segs = try await Task.detached(priority: .userInitiated) {
                try DiarizeRunner.diarize(
                    audio: paths.mixedWav,
                    outputDir: paths.transcriptDir,
                    logTo: paths.logFile
                )
            }.value

            let raw   = TranscriptMerger.mergeRaw(transcript: transcript, diarization: segs)
            let clean = TranscriptMerger.mergeClean(raw: raw)

            // 落盘
            try? TranscriptMerger.save(raw,   to: paths.multiSpeakerRawJSON)
            try? TranscriptMerger.save(clean, to: paths.multiSpeakerCleanJSON)

            // 登记多人稿版本
            _ = try? store.addTranscriptVersion(meetingID: meetingID, kind: "multispk_raw",   path: paths.multiSpeakerRawJSON)
            _ = try? store.addTranscriptVersion(meetingID: meetingID, kind: "multispk_clean", path: paths.multiSpeakerCleanJSON)

            speakerSegments = clean
            self.lastSpeakerSegments = clean
        } catch {
            // 分离失败：记录日志，继续用单人稿生成纪要，整场会议不失败
            let msg = "说话人分离降级: \(error.localizedDescription)"
            if let data = (msg + "\n").data(using: .utf8),
               let fh = try? FileHandle(forWritingTo: paths.logFile) {
                fh.seekToEndOfFile(); fh.write(data); try? fh.close()
            }
            self.lastError = msg   // UI 可选择展示降级提示
        }
        // ──────────────────────────────────────────────────────────────────

        // Gemma 纪要（分段摘要 + 二次汇总，防长会 OOM）
        self.processingStage = .summarizing
        taskQueue.updateStage(meetingID: meetingID, stage: .summarizing)
        let markdown: String
        do {
            let spk = speakerSegments
            markdown = try await Task.detached(priority: .userInitiated) {
                try GemmaRunner.summarizeSmart(
                    transcript: transcript,
                    speakerSegments: spk,
                    logTo: paths.logFile
                )
            }.value
        } catch {
            self.processingStage = .failed
            self.state = .failed(message: "纪要生成失败: \(error.localizedDescription)")
            markFailed(meetingID: meetingID, reason: "纪要失败: \(error.localizedDescription)")
            return
        }

        // 落盘 summary
        try? FileManager.default.createDirectory(at: paths.summaryDir, withIntermediateDirectories: true)
        let summaryPath = paths.summaryDir.appendingPathComponent("summary_v1.md")
        try? markdown.write(to: summaryPath, atomically: true, encoding: .utf8)
        _ = try? store.addSummaryVersion(
            meetingID: meetingID,
            path: summaryPath,
            model: GemmaRunner.model,
            promptHash: GemmaRunner.promptHash(markdown)
        )

        // 标题：取 summary 第一行非空作为标题（去掉 markdown 标记）
        let title = extractTitle(from: markdown) ?? defaultTitle(for: Date())
        let completed = Meeting(
            id: meetingID,
            title: title,
            createdAt: (try? store.meeting(id: meetingID))?.createdAt ?? Date(),
            durationMs: Int(elapsed * 1000),
            status: .completed,
            audioPath: paths.mixedWav.path
        )
        try? store.upsert(completed)

        self.lastSummaryMarkdown = markdown
        self.lastCompletedMeetingID = meetingID
        self.processingStage = .completed
        self.state = .idle
        taskQueue.markCompleted(meetingID: meetingID)
    }

    private func markFailed(meetingID: MeetingID, reason: String) {
        if var m = try? store.meeting(id: meetingID) {
            m.status = .failed
            m.failureReason = reason
            try? store.upsert(m)
        }
        taskQueue.markFailed(meetingID: meetingID, error: reason)
    }

    public var degraded: Bool { systemAudioDegraded }

    public func elapsedSeconds(at now: Date = Date()) -> TimeInterval {
        switch state {
        case .recording:
            let delta = resumedAt.map { now.timeIntervalSince($0) } ?? 0
            return pausedAccumulated + delta
        case .paused(let total):
            return total
        default:
            return 0
        }
    }

    private func defaultTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "会议 · \(f.string(from: date))"
    }

    /// 从纪要 Markdown 提取标题：
    /// 优先取 **会议概述** 节的第一句正文（去掉括号内的"无"）；
    /// 其次取第一个 `##` 或 `#` 标题文字；
    /// 都没有则返回 nil。
    private func extractTitle(from markdown: String) -> String? {
        let lines = markdown.components(separatedBy: "\n")

        // 找 "会议概述" 节，提取其后第一条非空正文
        var inOverview = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.contains("会议概述") {
                inOverview = true
                continue
            }
            if inOverview {
                // 下一个节标题 → 概述为空
                if t.hasPrefix("#") || t.hasPrefix("**") && t.hasSuffix("**") { break }
                let cleaned = t
                    .replacingOccurrences(of: "*", with: "")
                    .replacingOccurrences(of: "#", with: "")
                    .trimmingCharacters(in: .whitespaces)
                // 忽略 "（无）"
                if cleaned.isEmpty || cleaned == "（无）" || cleaned == "(无)" { break }
                // 取第一句（句号/。/！前）
                let sentence = cleaned.components(separatedBy: CharacterSet(charactersIn: "。.！!"))
                    .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                    ?? cleaned
                return String(sentence.trimmingCharacters(in: .whitespaces).prefix(40))
            }
        }

        // fallback：第一个标题行
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("##") || t.hasPrefix("# ") {
                let cleaned = t
                    .drop(while: { $0 == "#" || $0 == " " })
                    .trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty { return String(cleaned.prefix(40)) }
            }
        }
        return nil
    }
}
