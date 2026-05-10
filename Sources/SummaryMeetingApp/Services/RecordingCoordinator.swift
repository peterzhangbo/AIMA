import Foundation
import Observation
import AVFoundation

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

    // 后台处理队列（可在录制下一场会议时，后台串行处理上一场/上 N 场）
    /// 一个会议要么走完整流水线（转写+分离+纪要），要么仅重跑纪要（rerun）。
    /// 两类作业共享同一条串行队列，保证全局任意时刻只有 1 个 MLX 推理进程。
    fileprivate enum PipelineJob: Equatable {
        case full(MeetingID)
        case rerun(MeetingID)
        var meetingID: MeetingID {
            switch self { case .full(let id): return id; case .rerun(let id): return id }
        }
    }
    fileprivate var queue: [PipelineJob] = []
    public private(set) var queuedMeetingIDs: [MeetingID] = []
    public private(set) var activeProcessingMeetingID: MeetingID?
    public private(set) var activeProcessingStage: ProcessingStage?
    fileprivate var activeJob: PipelineJob?
    public private(set) var jobStartedAt: Date?

    /// 处理进度信息（供 UI 展示当前阶段 / 排队顺位 / 预计剩余时间）
    public struct ProgressInfo: Equatable {
        public enum Kind: Equatable {
            case queued(ahead: Int)
            case processing(stage: ProcessingStage)
        }
        public let kind: Kind
        /// 当前会议剩余预计秒数；无法估算（缺少音频时长）时为 nil。
        public let etaSeconds: Int?
    }
    /// UI 订阅此计数触发刷新：每当队列/状态变化时 +1
    public private(set) var pipelineTick: Int = 0

    private let store: MeetingStore
    private let taskQueue: TaskQueue
    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private var startedAt: Date?
    private var pausedAccumulated: TimeInterval = 0
    private var resumedAt: Date?
    private var systemAudioDegraded = false
    private var workerTask: Task<Void, Never>?
    private var clockTickerTask: Task<Void, Never>?

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
            // 落盘到日志，方便外发排查
            FileHandle.standardError.write(Data("[MicRecorder] \(reason)\n".utf8))
            self.state = .failed(message: reason)
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

    /// 停止录制 → 混音 → 登记为 queued 并入列后台流水线 → 立刻返回 idle
    /// 允许用户立即开始下一场录制，而上一场会议在后台继续 transcribe / diarize / summarize。
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
        let degraded = self.systemAudioDegraded

        // 混音（快速落盘；失败直接终结此会议，不进入队列）
        // mic.outputURL 可能是 .wav（正常）或 .m4a（AVAudioRecorder 格式降级后的回退）
        let micAudioURL: URL? = mic.outputURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
        do {
            try AudioMixer.mix(
                mic: micAudioURL,
                system: (!degraded && FileManager.default.fileExists(atPath: paths.systemAudio.path)) ? paths.systemAudio : nil,
                output: paths.mixedWav,
                logTo: paths.logFile
            )
        } catch {
            self.processingStage = .failed
            self.state = .failed(message: "混音失败: \(error.localizedDescription)")
            markFailed(meetingID: meetingID, reason: "混音失败: \(error.localizedDescription)")
            return
        }

        // 登记会议为 queued，历史侧栏可见
        if var m = try? store.meeting(id: meetingID) {
            m.status = .queued
            m.durationMs = Int(elapsed * 1000)
            m.audioPath = paths.mixedWav.path
            try? store.upsert(m)
        }
        taskQueue.upsert(ProcessingTask(meetingID: meetingID, stage: .transcribing))

        // 重置 capture 本场状态，让 state 立即回到 idle（可启动下一场录制）
        self.currentMeetingID = nil
        self.currentPaths = nil
        self.startedAt = nil
        self.resumedAt = nil
        self.pausedAccumulated = 0
        self.systemAudioDegraded = false
        self.processingStage = nil
        self.lastCompletedMeetingID = meetingID   // RecordingView onDone 据此选中该会议
        self.state = .idle

        // 入列到后台流水线
        enqueuePipeline(meetingID: meetingID)
    }

    // MARK: - 后台处理流水线

    /// 入列一个 job；若 worker 空闲则启动 drain 循环。同一 meeting 已在队列/正在处理时跳过。
    private func enqueueJob(_ job: PipelineJob) {
        let mid = job.meetingID
        if activeProcessingMeetingID == mid { return }
        if queue.contains(where: { $0.meetingID == mid }) { return }
        queue.append(job)
        queuedMeetingIDs = queue.map { $0.meetingID }
        pipelineTick &+= 1
        if workerTask == nil {
            workerTask = Task { [weak self] in
                await self?.drainQueue()
            }
            // 启动一个秒级 ticker，让 UI 中的"剩余时间"能持续刷新。
            clockTickerTask?.cancel()
            clockTickerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
                    if Task.isCancelled { break }
                    await MainActor.run {
                        guard let self = self, self.workerTask != nil else { return }
                        self.pipelineTick &+= 1
                    }
                }
            }
        }
    }

    private func enqueuePipeline(meetingID: MeetingID) {
        enqueueJob(.full(meetingID))
    }

    private func enqueueRerun(meetingID: MeetingID) {
        enqueueJob(.rerun(meetingID))
    }

    private func drainQueue() async {
        while !queue.isEmpty {
            let job = queue.removeFirst()
            queuedMeetingIDs = queue.map { $0.meetingID }
            let meetingID = job.meetingID
            activeProcessingMeetingID = meetingID
            activeJob = job
            jobStartedAt = Date()
            switch job {
            case .full:  activeProcessingStage = .transcribing
            case .rerun: activeProcessingStage = .summarizing
            }
            pipelineTick &+= 1
            switch job {
            case .full(let id):
                guard let paths = SessionPaths(meetingID: id) else {
                    markFailed(meetingID: id, reason: "流水线：会话目录丢失")
                    break
                }
                await runPipeline(meetingID: id, paths: paths)
            case .rerun(let id):
                await runRerun(meetingID: id)
            }
            activeProcessingMeetingID = nil
            activeProcessingStage = nil
            activeJob = nil
            jobStartedAt = nil
            pipelineTick &+= 1
        }
        workerTask = nil
        clockTickerTask?.cancel()
        clockTickerTask = nil
    }

    // MARK: - 进度信息（UI 展示用）

    /// 给定会议 ID 返回其在流水线里的处理状态：正在处理（含阶段+ETA）或排队中（含位次+ETA）。
    /// 若该会议既不在处理也不在队列，返回 nil。
    public func progressInfo(for meetingID: MeetingID) -> ProgressInfo? {
        if activeProcessingMeetingID == meetingID, let stage = activeProcessingStage {
            return ProgressInfo(kind: .processing(stage: stage),
                                etaSeconds: etaForActiveJob())
        }
        if let idx = queue.firstIndex(where: { $0.meetingID == meetingID }) {
            return ProgressInfo(kind: .queued(ahead: idx),
                                etaSeconds: etaForQueuedJob(at: idx))
        }
        return nil
    }

    /// 用音频时长估算单个 job 的总耗时（秒）。
    /// M 系列芯片粗略基线：whisper ≈ 0.6×audio, diarize ≈ 0.4×audio, gemma ≈ max(45, 0.15×audio)。
    private func expectedJobSeconds(_ job: PipelineJob, audioSec: Double) -> Double {
        switch job {
        case .full:
            // 转写 + 分离 + 纪要 + 杂项 buffer
            return max(60, audioSec * 1.15) + 45
        case .rerun:
            return max(45, audioSec * 0.20)
        }
    }

    /// 每个会议的音频时长缓存（避免 UI 每行每 5 秒一次 SQLite 查询）。
    /// 命中后不再查 DB；durationMs 在 `stopAndProcess` 之后基本不变，缓存安全。
    private var audioDurationCache: [MeetingID: Double] = [:]

    private func audioDurationSeconds(_ id: MeetingID) -> Double? {
        if let cached = audioDurationCache[id] { return cached }
        guard let m = try? store.meeting(id: id), m.durationMs > 0 else { return nil }
        let sec = Double(m.durationMs) / 1000
        audioDurationCache[id] = sec
        return sec
    }

    private func etaForActiveJob() -> Int? {
        guard let job = activeJob,
              let started = jobStartedAt,
              let audio = audioDurationSeconds(job.meetingID) else { return nil }
        let total = expectedJobSeconds(job, audioSec: audio)
        let remaining = total - Date().timeIntervalSince(started)
        return Int(max(15, remaining))
    }

    private func etaForQueuedJob(at idx: Int) -> Int? {
        var sum: Double = 0
        // 当前正在处理的 job 还剩多少
        if let active = activeJob,
           let started = jobStartedAt,
           let audio = audioDurationSeconds(active.meetingID) {
            let total = expectedJobSeconds(active, audioSec: audio)
            sum += max(0, total - Date().timeIntervalSince(started))
        }
        // 队列里排在前面的所有 job
        for i in 0..<idx {
            let aheadJob = queue[i]
            if let a = audioDurationSeconds(aheadJob.meetingID) {
                sum += expectedJobSeconds(aheadJob, audioSec: a)
            } else {
                return nil // 缺数据，给不出可靠 ETA
            }
        }
        // 自身这条 job
        guard idx < queue.count else { return nil }
        let own = queue[idx]
        guard let ownAudio = audioDurationSeconds(own.meetingID) else { return nil }
        sum += expectedJobSeconds(own, audioSec: ownAudio)
        return Int(max(30, sum))
    }

    /// 单个会议的完整处理流水线：transcribe → diarize（可降级）→ summary → finalize
    private func runPipeline(meetingID: MeetingID, paths: SessionPaths) async {
        // 标记为 processing
        if var m = try? store.meeting(id: meetingID) {
            m.status = .processing
            try? store.upsert(m)
        }

        // Whisper 转写
        activeProcessingStage = .transcribing
        pipelineTick &+= 1
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
            markFailed(meetingID: meetingID, reason: "转写失败: \(error.localizedDescription)")
            return
        }

        // 落盘合并后的 transcript
        let transcriptPath = paths.transcriptDir.appendingPathComponent("mixed.json")
        if !FileManager.default.fileExists(atPath: transcriptPath.path),
           let data = try? JSONEncoder().encode(transcript) {
            try? data.write(to: transcriptPath, options: .atomic)
        }
        _ = try? store.addTranscriptVersion(meetingID: meetingID, kind: "raw", path: transcriptPath)

        // 说话人分离（可降级）
        activeProcessingStage = .diarizing
        pipelineTick &+= 1
        taskQueue.updateStage(meetingID: meetingID, stage: .diarizing)
        let speakerSegments = await runDiarizeAndPersist(
            meetingID: meetingID, paths: paths, transcript: transcript
        )

        // Gemma 纪要
        activeProcessingStage = .summarizing
        pipelineTick &+= 1
        taskQueue.updateStage(meetingID: meetingID, stage: .summarizing)
        let spk = speakerSegments
        let promptHash = GemmaRunner.promptHash(
            SummaryPrompt.build(transcript: transcript, speakerSegments: spk)
        )
        let markdown: String
        do {
            markdown = try await Task.detached(priority: .userInitiated) {
                try GemmaRunner.summarizeSmart(
                    transcript: transcript,
                    speakerSegments: spk,
                    logTo: paths.logFile
                )
            }.value
        } catch {
            markFailed(meetingID: meetingID, reason: "纪要生成失败: \(error.localizedDescription)")
            return
        }

        // 提示偏漂检查：必需小节缺失时写日志，方便排查 prompt drift
        logMissingSummarySections(markdown: markdown, logTo: paths.logFile)

        // 落盘 summary：按已有版本数递增文件名，避免崩溃恢复覆盖旧版本
        try? FileManager.default.createDirectory(at: paths.summaryDir, withIntermediateDirectories: true)
        let existingCount = (try? store.allSummaryVersions(meetingID: meetingID).count) ?? 0
        let summaryPath = paths.summaryDir.appendingPathComponent("summary_v\(existingCount + 1).md")
        try? markdown.write(to: summaryPath, atomically: true, encoding: .utf8)
        _ = try? store.addSummaryVersion(
            meetingID: meetingID,
            path: summaryPath,
            model: GemmaRunner.model,
            promptHash: promptHash
        )

        // finalize：标题 + status=.completed
        // 注意：保留 runDiarizeAndPersist 写入的"说话人分离降级"警告，
        // 让详情页在纪要完成后仍能显示分离降级提示；其它失败原因（如旧的失败）才清除。
        let title = extractTitle(from: markdown) ?? defaultTitle(for: Date())
        if var m = try? store.meeting(id: meetingID) {
            m.title = title
            m.status = .completed
            if !((m.failureReason ?? "").hasPrefix("说话人分离降级")) {
                m.failureReason = nil
            }
            try? store.upsert(m)
        }
        taskQueue.markCompleted(meetingID: meetingID)
        self.lastCompletedMeetingID = meetingID
        pipelineTick &+= 1
    }

    // MARK: - 崩溃恢复

    /// App 启动后检查 DB 中遗留的 running 任务，按情况重入流水线或标记失败。
    /// 同时回收"孤儿"会议：DB 状态为 .processing/.queued 但 TaskQueue 没有 running 记录的，
    /// 那是 v1.0 之前 rerun 没持久化导致的卡死会议——这里自动补一条 task 并重入队列。
    /// stage=.summarizing 且转写已存在的视为 rerun 任务（只重跑纪要），否则视为完整流水线。
    public func resumePendingTasks() async {
        let pendingRunning = taskQueue.pendingTasks()
        // 1) 处理已知 running 任务
        for task in pendingRunning {
            await reenqueueOrFail(meetingID: task.meetingID, knownStage: task.stage)
        }
        // 2) 回收 DB 里状态卡住但 TaskQueue 没记录的会议
        let allMeetings = (try? store.listMeetings()) ?? []
        let runningIDs = Set(pendingRunning.map { $0.meetingID })
        for m in allMeetings {
            guard m.status == .processing || m.status == .queued else { continue }
            if runningIDs.contains(m.id) { continue }
            await reenqueueOrFail(meetingID: m.id, knownStage: nil)
        }
    }

    /// 共用：根据已有产物决定恢复方式（rerun / 完整流水线 / 标记失败）
    private func reenqueueOrFail(meetingID: MeetingID, knownStage: ProcessingStage?) async {
        guard let paths = SessionPaths(meetingID: meetingID) else {
            markFailed(meetingID: meetingID, reason: "恢复：会话目录丢失")
            return
        }
        let transcriptOK = FileManager.default.fileExists(atPath: paths.transcriptJSON.path)
        let mixedOK = FileManager.default.fileExists(atPath: paths.mixedWav.path)
        // stage=summarizing 且已有转写 → rerun；DB 里推断不出 stage 时，转写存在也优先走 rerun（更快、不丢已有结果）
        if (knownStage == .summarizing || knownStage == nil) && transcriptOK {
            enqueueRerun(meetingID: meetingID)
            return
        }
        if mixedOK {
            enqueuePipeline(meetingID: meetingID)
        } else {
            markFailed(meetingID: meetingID, reason: "恢复失败：缺少混音和转写，请重新录制")
        }
    }

    // MARK: - 失败重试

    /// 失败会议的重试入口：根据已产出的中间产物判断从哪一步恢复。
    /// - 若混音文件存在 → 重新入列完整流水线（转写 + 说话人 + 纪要）
    /// - 否则 → 无法自动恢复
    public func retryProcessing(for meetingID: MeetingID) async {
        if activeProcessingMeetingID == meetingID || queuedMeetingIDs.contains(meetingID) {
            return
        }
        guard let paths = SessionPaths(meetingID: meetingID) else {
            taskQueue.markFailed(meetingID: meetingID, error: "找不到会议目录")
            return
        }
        guard FileManager.default.fileExists(atPath: paths.mixedWav.path) else {
            taskQueue.markFailed(meetingID: meetingID, error: "缺少录音文件，无法重试；请重新录制")
            if var m = try? store.meeting(id: meetingID) {
                m.failureReason = "缺少录音文件，无法重试；请重新录制"
                try? store.upsert(m)
            }
            return
        }
        // 清除失败状态，重置为处理中
        if var m = try? store.meeting(id: meetingID) {
            m.status = .processing
            m.failureReason = nil
            try? store.upsert(m)
        }
        taskQueue.upsert(ProcessingTask(meetingID: meetingID, stage: .transcribing))
        enqueuePipeline(meetingID: meetingID)
    }

    // MARK: - 重新生成纪要

    /// 对历史会议重新跑 Gemma（不重新录音/转写），产出新版本并写 DB。
    /// 通过同一条串行队列调度，不会与其它流水线 job 并发跑 MLX。
    public func rerunSummary(for meetingID: MeetingID) async {
        // 已在队列中或正在处理 → 直接返回，避免重复入列
        if activeProcessingMeetingID == meetingID
            || queue.contains(where: { $0.meetingID == meetingID }) {
            return
        }
        guard SessionPaths(meetingID: meetingID) != nil else {
            taskQueue.markFailed(meetingID: meetingID, error: "找不到会议目录")
            return
        }
        // 立刻把状态置为 .processing（即便排队中也显示生成中），UI 徽标会跟着变
        if var m = try? store.meeting(id: meetingID) {
            m.status = .processing
            m.failureReason = nil
            try? store.upsert(m)
        }
        // 把 rerun 也写入 TaskQueue（stage=summarizing），让崩溃恢复能识别这是重跑而非全流水线
        taskQueue.upsert(ProcessingTask(meetingID: meetingID, stage: .summarizing))
        enqueueRerun(meetingID: meetingID)
    }

    /// rerunSummary 的实际执行逻辑（在串行 worker 中调用）。
    /// drainQueue 已设置 activeProcessingStage = .summarizing 与 jobStartedAt，故此处不重置。
    private func runRerun(meetingID: MeetingID) async {
        guard let paths = SessionPaths(meetingID: meetingID) else {
            markFailed(meetingID: meetingID, reason: "找不到会议目录")
            return
        }
        // 加载 transcript
        let transcript: Transcript
        do {
            transcript = try WhisperRunner.parseTranscript(jsonURL: paths.transcriptJSON)
        } catch {
            markFailed(meetingID: meetingID, reason: "加载转写失败: \(error.localizedDescription)")
            pipelineTick &+= 1
            return
        }

        // 加载最新多人稿版本（优先走 DB 的最新 version；兜底老路径）
        var speakerSegments: [SpeakerSegment]? = {
            if let v = try? store.latestTranscript(meetingID: meetingID, kind: "multispk_clean") {
                return try? TranscriptMerger.load(from: URL(fileURLWithPath: v.path))
            }
            return try? TranscriptMerger.load(from: paths.multiSpeakerCleanJSON)
        }()

        // 多人稿缺失（早期版本因 build_release.sh 路径 bug 导致 diarize 静默失败）：
        // 在重跑纪要时顺带补救——若混音文件还在，就先跑一次 diarize 生成多人稿。
        if speakerSegments == nil,
           FileManager.default.fileExists(atPath: paths.mixedWav.path) {
            activeProcessingStage = .diarizing
            pipelineTick &+= 1
            taskQueue.updateStage(meetingID: meetingID, stage: .diarizing)
            speakerSegments = await runDiarizeAndPersist(
                meetingID: meetingID, paths: paths, transcript: transcript
            )
            activeProcessingStage = .summarizing
            pipelineTick &+= 1
            taskQueue.updateStage(meetingID: meetingID, stage: .summarizing)
        }

        let promptHash = GemmaRunner.promptHash(
            SummaryPrompt.build(transcript: transcript, speakerSegments: speakerSegments)
        )
        let spk = speakerSegments
        let markdown: String
        do {
            markdown = try await Task.detached(priority: .userInitiated) {
                try GemmaRunner.summarizeSmart(
                    transcript: transcript,
                    speakerSegments: spk,
                    logTo: paths.logFile
                )
            }.value
        } catch {
            markFailed(meetingID: meetingID, reason: "纪要生成失败: \(error.localizedDescription)")
            pipelineTick &+= 1
            return
        }

        // 提示偏漂检查
        logMissingSummarySections(markdown: markdown, logTo: paths.logFile)

        // 落盘新版本
        try? FileManager.default.createDirectory(at: paths.summaryDir, withIntermediateDirectories: true)
        let existing = (try? FileManager.default.contentsOfDirectory(at: paths.summaryDir,
            includingPropertiesForKeys: nil))?.count ?? 0
        let summaryPath = paths.summaryDir.appendingPathComponent("summary_v\(existing + 1).md")
        try? markdown.write(to: summaryPath, atomically: true, encoding: .utf8)
        _ = try? store.addSummaryVersion(
            meetingID: meetingID, path: summaryPath,
            model: GemmaRunner.model, promptHash: promptHash
        )

        // 更新标题 + 恢复会议状态为 completed（兼容失败会议重试成功的场景）
        // 同 runPipeline finalize：保留分离降级提示
        if var m = try? store.meeting(id: meetingID) {
            if let title = extractTitle(from: markdown) { m.title = title }
            m.status = .completed
            if !((m.failureReason ?? "").hasPrefix("说话人分离降级")) {
                m.failureReason = nil
            }
            if (m.audioPath?.isEmpty ?? true),
               FileManager.default.fileExists(atPath: paths.mixedWav.path) {
                m.audioPath = paths.mixedWav.path
            }
            if m.durationMs <= 0, let path = m.audioPath, !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                if let ms = await probeDurationMs(url: url) { m.durationMs = ms }
            }
            try? store.upsert(m)
        }
        taskQueue.markCompleted(meetingID: meetingID)
        pipelineTick &+= 1
    }

    /// 读取音频时长（毫秒），读取失败返回 nil。用于补齐重试成功后缺失的元数据。
    private func probeDurationMs(url: URL) async -> Int? {
        let asset = AVURLAsset(url: url)
        do {
            let cm = try await asset.load(.duration)
            guard cm.isValid, !cm.isIndefinite, cm.seconds.isFinite, cm.seconds > 0 else { return nil }
            return Int(cm.seconds * 1000)
        } catch {
            return nil
        }
    }

    /// 跑说话人分离并落盘多人稿。失败不抛异常，仅写日志和 meeting.failureReason
    /// 让 UI 能识别"分离降级"，主流程继续生成纪要。
    private func runDiarizeAndPersist(
        meetingID: MeetingID,
        paths: SessionPaths,
        transcript: Transcript
    ) async -> [SpeakerSegment]? {
        do {
            let segs = try await Task.detached(priority: .userInitiated) {
                try DiarizeRunner.diarize(
                    audio: paths.mixedWav,
                    outputDir: paths.transcriptDir,
                    logTo: paths.logFile
                )
            }.value
            let raw = TranscriptMerger.mergeRaw(transcript: transcript, diarization: segs)
            let clean = TranscriptMerger.mergeClean(raw: raw)
            try? TranscriptMerger.save(raw,   to: paths.multiSpeakerRawJSON)
            try? TranscriptMerger.save(clean, to: paths.multiSpeakerCleanJSON)
            _ = try? store.addTranscriptVersion(meetingID: meetingID, kind: "multispk_raw",   path: paths.multiSpeakerRawJSON)
            _ = try? store.addTranscriptVersion(meetingID: meetingID, kind: "multispk_clean", path: paths.multiSpeakerCleanJSON)
            // 分离成功，清理之前可能留下的"分离降级"提示
            if var m = try? store.meeting(id: meetingID),
               (m.failureReason ?? "").hasPrefix("说话人分离降级") {
                m.failureReason = nil
                try? store.upsert(m)
            }
            return clean
        } catch {
            let msg = "说话人分离降级: \(error.localizedDescription)"
            if let data = (msg + "\n").data(using: .utf8) {
                if !FileManager.default.fileExists(atPath: paths.logFile.path) {
                    try? data.write(to: paths.logFile, options: .atomic)
                } else if let fh = try? FileHandle(forWritingTo: paths.logFile) {
                    fh.seekToEndOfFile(); fh.write(data); try? fh.close()
                }
            }
            // 不影响主流程；但写入 failureReason 让详情页能显示提示。会议状态最终仍是 completed。
            if var m = try? store.meeting(id: meetingID) {
                m.failureReason = msg
                try? store.upsert(m)
            }
            return nil
        }
    }

    /// 把 GemmaRunner.missingSectionHeaders 的结果写到会议日志，方便事后排查 prompt drift。
    private func logMissingSummarySections(markdown: String, logTo: URL) {
        let missing = GemmaRunner.missingSectionHeaders(markdown)
        guard !missing.isEmpty else { return }
        let line = "[summary-warn] 缺失模板小节: \(missing.joined(separator: ", "))\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: logTo.path) {
            try? data.write(to: logTo, options: .atomic)
        } else if let fh = try? FileHandle(forWritingTo: logTo) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        }
    }

    private func markFailed(meetingID: MeetingID, reason: String) {
        // 写到 stderr，被 LogCapture 捕获到 ~/Library/Logs/AIMA/aima-*.log
        FileHandle.standardError.write(Data("[RecordingCoordinator] meeting \(meetingID.raw) failed: \(reason)\n".utf8))
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
    /// 1. 优先取 **会议标题** 节的正文（prompt 已要求 ≤15 字短语）；
    /// 2. 其次取 **会议概述** 第一句并截断到 15 字；
    /// 3. 否则取第一个 `##`/`#` 标题并截断。
    private func extractTitle(from markdown: String) -> String? {
        let lines = markdown.components(separatedBy: "\n")

        func strip(_ s: String) -> String {
            s.replacingOccurrences(of: "*", with: "")
             .replacingOccurrences(of: "#", with: "")
             .replacingOccurrences(of: "「", with: "")
             .replacingOccurrences(of: "」", with: "")
             .replacingOccurrences(of: "\"", with: "")
             .replacingOccurrences(of: "“", with: "")
             .replacingOccurrences(of: "”", with: "")
             .replacingOccurrences(of: "。", with: "")
             .trimmingCharacters(in: .whitespaces)
        }
        func cap(_ s: String, _ n: Int = 15) -> String { String(s.prefix(n)) }
        func isEmptyMarker(_ s: String) -> Bool {
            s.isEmpty || s == "（无）" || s == "(无)" || s == "无"
        }

        // 1. 会议标题节：标题可能在同一行（`**会议标题**：xxx`）或下一行
        for (i, rawLine) in lines.enumerated() {
            let t = rawLine.trimmingCharacters(in: .whitespaces)
            guard t.contains("会议标题") else { continue }
            // 尝试同一行冒号后内容
            let sep = CharacterSet(charactersIn: "：:")
            let parts = t.components(separatedBy: sep)
            if parts.count >= 2 {
                let inline = strip(parts.dropFirst().joined(separator: ":"))
                if !isEmptyMarker(inline) { return cap(inline) }
            }
            // 否则扫描后续非空行（跳过空行与 markdown 装饰）
            for j in (i + 1)..<lines.count {
                let nt = lines[j].trimmingCharacters(in: .whitespaces)
                if nt.isEmpty { continue }
                let cleaned = strip(nt)
                if isEmptyMarker(cleaned) { break }
                // 碰到下一个 section 标题就停
                if nt.hasPrefix("#") || (nt.hasPrefix("**") && nt.hasSuffix("**") && !nt.contains("：") && !nt.contains(":")) { break }
                // 去掉列表前缀 "- " "1. " 等
                var v = cleaned
                if v.hasPrefix("- ") || v.hasPrefix("* ") { v = String(v.dropFirst(2)) }
                if !v.isEmpty { return cap(v) }
            }
            break
        }

        // 2. 兜底：第一个 markdown 标题
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("##") || t.hasPrefix("# ") {
                let cleaned = t.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty { return cap(cleaned) }
            }
        }
        return nil
    }
}
