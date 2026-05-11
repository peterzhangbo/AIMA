import Foundation
import AVFoundation
import CoreGraphics
@preconcurrency import ScreenCaptureKit

public enum SystemAudioCaptureError: Error, LocalizedError {
    case noDisplay
    case unauthorized
    case writerCreationFailed(String)
    case streamStartFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noDisplay: return "未发现可用屏幕 display，系统音频无法采集"
        case .unauthorized: return "未获得屏幕录制权限"
        case .writerCreationFailed(let m): return "音频文件写入初始化失败: \(m)"
        case .streamStartFailed(let m): return "ScreenCaptureKit 启动失败: \(m)"
        }
    }
}

/// ScreenCaptureKit 录制系统音频到 m4a 文件。
/// 采集策略：优先绑定会议 App 所在显示器，减少切屏中断。
/// 中断恢复：流意外停止时最多重启一次，多段音频在 stop() 时合并。
public final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    // MARK: - 常量

    private static let meetingBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams", "com.microsoft.teams2",
        "com.tencent.meetingmac",
        "com.alibaba.DingTalk",
        "com.tencent.xinteams",
        "com.apple.FaceTime",
        "com.cisco.webexmeetingsapp",
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
    ]
    private static let maxRestarts = 1

    // MARK: - State

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "system-audio-capture")
    private var sessionStarted = false
    private var isPaused: Bool = false

    /// 主输出路径（最终产物）
    public private(set) var outputURL: URL?
    public private(set) var lastError: Error?

    /// 中断恢复产生的额外分段（最终合并入 outputURL）
    private var segmentURLs: [URL] = []
    private var restartCount = 0

    // MARK: - Public API

    public func start(to url: URL) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        outputURL = url
        segmentURLs = []
        restartCount = 0

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw SystemAudioCaptureError.unauthorized
        }
        guard let display = preferredDisplay(from: content) else {
            throw SystemAudioCaptureError.noDisplay
        }

        try await startStream(to: url, display: display)
    }

    public func pause()  { isPaused = true }
    public func resume() { isPaused = false }

    public func stop() async {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        await finishWriting()
        // 合并分段（若有中断恢复）
        if let base = outputURL, !segmentURLs.isEmpty {
            mergeSegments(primary: base, extras: segmentURLs)
            segmentURLs = []
        }
    }

    // MARK: - Internal start helper

    private func startStream(to url: URL, display: SCDisplay) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        try setupWriter(url: url)

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await s.startCapture()
        } catch {
            throw SystemAudioCaptureError.streamStartFailed(error.localizedDescription)
        }
        self.stream = s
    }

    // MARK: - Auto-restart after interruption

    /// 流中断时最多重启一次，新段写到临时文件，stop() 时合并。
    private func attemptRestart() async {
        guard restartCount < Self.maxRestarts, let base = outputURL else { return }

        // 完成当前分段写入
        await finishWriting()
        restartCount += 1

        let segURL = base.deletingPathExtension()
            .appendingPathExtension("seg\(restartCount).m4a")
        segmentURLs.append(segURL)

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = preferredDisplay(from: content) else { return }
            try await startStream(to: segURL, display: display)
        } catch {
            self.lastError = error
        }
    }

    // MARK: - Segment merge

    private func mergeSegments(primary: URL, extras: [URL]) {
        let dir = primary.deletingLastPathComponent()
        let concatFile = dir.appendingPathComponent("_concat_list.txt")
        let mergedFile = dir.appendingPathComponent("_merged.m4a")

        // 只合并实际存在且有内容的文件
        func isValid(_ url: URL) -> Bool {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return size > 1024   // 至少 1 KB 才算有效段
        }
        let primaryValid = isValid(primary)
        let validExtras = extras.filter(isValid)
        let allFiles = (primaryValid ? [primary] : []) + validExtras

        guard allFiles.count > 1 else {
            // 若 primary 为空但 extra 有效：把第一个有效 extra 提升为 primary，避免丢失录音
            if !primaryValid, let rescue = validExtras.first {
                try? FileManager.default.removeItem(at: primary)
                try? FileManager.default.moveItem(at: rescue, to: primary)
            }
            extras.forEach { try? FileManager.default.removeItem(at: $0) }
            try? FileManager.default.removeItem(at: concatFile)
            return
        }

        let lines = allFiles.map { "file '\($0.path)'" }.joined(separator: "\n")
        try? lines.write(to: concatFile, atomically: true, encoding: .utf8)

        let mergeResult = try? ProcessRunner.run(
            executable: "ffmpeg",
            arguments: ["-y", "-f", "concat", "-safe", "0",
                        "-i", concatFile.path, "-c", "copy", mergedFile.path]
        )

        // 仅在 ffmpeg 成功且产物存在且非空时才替换 primary 并清理 extras。
        // 失败路径下保留所有原始分段（primary + extras），避免中断后录到的音频丢失。
        let mergedExists = FileManager.default.fileExists(atPath: mergedFile.path)
        let mergedSize = (try? FileManager.default.attributesOfItem(atPath: mergedFile.path)[.size] as? Int) ?? 0
        let succeeded = (mergeResult?.succeeded ?? false) && mergedExists && mergedSize > 1024

        if succeeded {
            try? FileManager.default.removeItem(at: primary)
            try? FileManager.default.moveItem(at: mergedFile, to: primary)
            // 合并成功才清理 extras
            extras.forEach { try? FileManager.default.removeItem(at: $0) }
        } else {
            // 失败：清理半成品 mergedFile，但保留 extras 供后续手动恢复或后台重试
            try? FileManager.default.removeItem(at: mergedFile)
            let stderr = mergeResult?.stderr ?? "(no stderr)"
            FileHandle.standardError.write(Data("[SystemAudioRecorder] ffmpeg concat 失败，保留分段：\(extras.map { $0.lastPathComponent }) \(stderr)\n".utf8))
        }
        try? FileManager.default.removeItem(at: concatFile)
    }

    // MARK: - Display selection

    private func preferredDisplay(from content: SCShareableContent) -> SCDisplay? {
        for window in content.windows {
            guard let app = window.owningApplication,
                  Self.meetingBundleIDs.contains(app.bundleIdentifier) else { continue }
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            if let display = content.displays.first(where: { $0.frame.contains(center) }) {
                return display
            }
        }
        return content.displays.first
    }

    // MARK: - Writer

    private func setupWriter(url: URL) throws {
        sessionStarted = false
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .m4a)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard w.canAdd(input) else {
                throw SystemAudioCaptureError.writerCreationFailed("无法添加音频 input")
            }
            w.add(input)
            guard w.startWriting() else {
                throw SystemAudioCaptureError.writerCreationFailed(
                    w.error?.localizedDescription ?? "startWriting 失败")
            }
            self.writer = w
            self.audioInput = input
        } catch let e as SystemAudioCaptureError {
            throw e
        } catch {
            throw SystemAudioCaptureError.writerCreationFailed(error.localizedDescription)
        }
    }

    private func finishWriting() async {
        guard let w = writer else { return }
        audioInput?.markAsFinished()
        await w.finishWriting()
        writer = nil
        audioInput = nil
        sessionStarted = false
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard !isPaused else { return }
        guard let w = writer, let input = audioInput else { return }

        if !sessionStarted {
            let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            w.startSession(atSourceTime: ts)
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.lastError = error
        // 尝试自动重绑新流
        Task { await self.attemptRestart() }
    }

    // MARK: - Permission probe

    /// 触发 ScreenCaptureKit TCC 注册。
    /// 调用 SCShareableContent 是让 App 出现在「系统设置 → 录屏与系统录音」列表的
    /// 唯一可靠方式；即使 throw（未授权），注册副作用依然生效。
    /// CGRequestScreenCaptureAccess 是 CGWindowList 旧 API，在 macOS 14/15 上
    /// 不会把 App 写入 ScreenCaptureKit 专属的 TCC 列表，故不再使用。
    @discardableResult
    public static func requestPermissionPrompt() async -> Bool {
        // SCShareableContent 调用失败时同样会把 App 写进 TCC 列表（这是副作用）
        _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return CGPreflightScreenCaptureAccess()
    }

    /// 仅检查当前权限状态，不触发弹窗（用于静默 probe）。
    public static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 打开系统设置的录屏权限页。
    public static func openScreenCaptureSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
