import Foundation
import AVFoundation
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

/// ScreenCaptureKit 录制系统音频到 wav 文件（M1 使用 display 硬编码策略）。
public final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "system-audio-capture")
    private var sessionStarted = false
    public private(set) var outputURL: URL?
    public private(set) var lastError: Error?

    public func start(to url: URL) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw SystemAudioCaptureError.unauthorized
        }
        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplay
        }

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

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            throw SystemAudioCaptureError.streamStartFailed(error.localizedDescription)
        }
        self.stream = stream
        self.outputURL = url
    }

    public func stop() async {
        if let stream = stream {
            try? await stream.stopCapture()
        }
        stream = nil
        await finishWriting()
    }

    private func setupWriter(url: URL) throws {
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw SystemAudioCaptureError.writerCreationFailed("无法添加音频 input")
            }
            writer.add(input)
            guard writer.startWriting() else {
                throw SystemAudioCaptureError.writerCreationFailed(writer.error?.localizedDescription ?? "startWriting 失败")
            }
            self.writer = writer
            self.audioInput = input
        } catch {
            throw SystemAudioCaptureError.writerCreationFailed(error.localizedDescription)
        }
    }

    private func finishWriting() async {
        guard let writer = writer else { return }
        audioInput?.markAsFinished()
        await writer.finishWriting()
        self.writer = nil
        self.audioInput = nil
        self.sessionStarted = false
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let writer = writer, let input = audioInput else { return }

        if !sessionStarted {
            let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: ts)
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.lastError = error
    }

    public static func requestPermissionPrompt() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }
}
