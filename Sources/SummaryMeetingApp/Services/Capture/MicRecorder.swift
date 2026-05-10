import Foundation
import AVFoundation

/// 麦克风录音器。
/// 优先用 AVAudioEngine（installTap → AVAudioFile），完全绕开 AVAudioRecorder；
/// 若 AVAudioEngine.start() 也失败，再依次尝试 AVAudioRecorder 的多种格式候选。
public final class MicRecorder: NSObject, @unchecked Sendable {

    // MARK: - State

    private enum Backend {
        case engine(AVAudioEngine, AVAudioFile)
        case recorder(AVAudioRecorder)
    }

    private var backend: Backend?
    public private(set) var outputURL: URL?

    // pause 标志：engine 模式下暂停时不写入磁盘，recorder 模式直接调 pause()
    private var isPaused = false

    // MARK: - Public API

    public func start(to url: URL) throws {
        // ── 预检 1：TCC 授权 ──────────────────────────────────────────
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard authStatus == .authorized else {
            let label: String = {
                switch authStatus {
                case .notDetermined: return "未请求（请在权限页点击 请求权限 按钮）"
                case .denied:        return "被拒绝（系统设置 → 隐私与安全性 → 麦克风 → 重新勾选 AIMA）"
                case .restricted:    return "受限（家长控制/MDM 阻止）"
                default:             return "状态：\(authStatus.rawValue)"
                }
            }()
            throw NSError(domain: "MicRecorder", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "麦克风未授权——\(label)"])
        }

        // ── 预检 2：目录可写 ──────────────────────────────────────────
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw NSError(domain: "MicRecorder", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "录音目录不可写：\(parent.path)"])
        }

        // ── 方案 A：AVAudioEngine（主力）─────────────────────────────
        if let result = try? startWithEngine(to: url) {
            self.backend = .engine(result.0, result.1)
            self.outputURL = url
            print("[MicRecorder] ✓ AVAudioEngine 模式启动成功，输出：\(url.lastPathComponent)")
            return
        }
        print("[MicRecorder] AVAudioEngine 失败，回退到 AVAudioRecorder 候选")

        // ── 方案 B：AVAudioRecorder 多格式候选（回退）────────────────
        let nativeSR = Self.deviceNativeSampleRate()
        let candidates: [(URL, [String: Any])] = [
            (url, [AVFormatIDKey: Int(kAudioFormatLinearPCM),
                   AVSampleRateKey: nativeSR,
                   AVNumberOfChannelsKey: 1,
                   AVLinearPCMBitDepthKey: 16,
                   AVLinearPCMIsFloatKey: false,
                   AVLinearPCMIsBigEndianKey: false]),
            (url, [AVFormatIDKey: Int(kAudioFormatLinearPCM),
                   AVSampleRateKey: nativeSR,
                   AVNumberOfChannelsKey: 1,
                   AVLinearPCMBitDepthKey: 32,
                   AVLinearPCMIsFloatKey: true,
                   AVLinearPCMIsBigEndianKey: false]),
            (url, [AVFormatIDKey: Int(kAudioFormatLinearPCM),
                   AVSampleRateKey: 44_100.0,
                   AVNumberOfChannelsKey: 1,
                   AVLinearPCMBitDepthKey: 16,
                   AVLinearPCMIsFloatKey: false,
                   AVLinearPCMIsBigEndianKey: false]),
            (url.deletingPathExtension().appendingPathExtension("m4a"),
             [AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
              AVSampleRateKey: 44_100.0,
              AVNumberOfChannelsKey: 1,
              AVEncoderBitRateKey: 128_000,
              AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]),
        ]

        for (idx, (targetURL, settings)) in candidates.enumerated() {
            do {
                let rec = try AVAudioRecorder(url: targetURL, settings: settings)
                rec.isMeteringEnabled = true
                guard rec.prepareToRecord() else {
                    print("[MicRecorder] 候选\(idx+1) prepareToRecord 失败")
                    continue
                }
                var ok = rec.record()
                if !ok { Thread.sleep(forTimeInterval: 0.2); ok = rec.record() }
                if ok {
                    print("[MicRecorder] ✓ AVAudioRecorder 候选\(idx+1) 成功")
                    self.backend   = .recorder(rec)
                    self.outputURL = targetURL
                    return
                }
                print("[MicRecorder] 候选\(idx+1) record() 返回 false")
            } catch {
                print("[MicRecorder] 候选\(idx+1) 创建失败：\(error.localizedDescription)")
            }
        }

        throw NSError(domain: "MicRecorder", code: 2,
                      userInfo: [NSLocalizedDescriptionKey:
                        "麦克风录音无法启动（已尝试 AVAudioEngine + \(candidates.count) 种 AVAudioRecorder 格式）。"
                        + "请关闭其它正在录音/通话的 App 后重试。"
                        + "  输出路径：\(url.path)"])
    }

    public func stop() {
        switch backend {
        case .engine(let eng, _):
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
        case .recorder(let rec):
            rec.stop()
        case nil:
            break
        }
        backend   = nil
        isPaused  = false
    }

    public func pause() {
        isPaused = true
        if case .recorder(let rec) = backend { rec.pause() }
    }

    public func resume() {
        isPaused = false
        if case .recorder(let rec) = backend { rec.record() }
    }

    public var currentTime: TimeInterval {
        switch backend {
        case .engine(_, let file):
            // file.length = 已写入的帧数（写入线程更新，主线程读取，轻微竞争可接受——仅用于 UI 显示）
            return Double(file.length) / file.processingFormat.sampleRate
        case .recorder(let rec):
            return rec.currentTime
        case nil:
            return 0
        }
    }

    // MARK: - Permissions

    public static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    public static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Private: AVAudioEngine

    private func startWithEngine(to url: URL) throws -> (AVAudioEngine, AVAudioFile) {
        let engine    = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFmt     = inputNode.inputFormat(forBus: 0)

        print("[MicRecorder] AVAudioEngine 硬件格式：sr=\(hwFmt.sampleRate) ch=\(hwFmt.channelCount)")
        guard hwFmt.sampleRate > 0 else {
            throw NSError(domain: "MicRecorder", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "AVAudioEngine 无法获取有效输入格式"])
        }

        // 录制文件格式：单声道 16-bit PCM（ffmpeg/whisper 通用）
        let fileFmt: [String: Any] = [
            AVFormatIDKey:           Int(kAudioFormatLinearPCM),
            AVSampleRateKey:         hwFmt.sampleRate,
            AVNumberOfChannelsKey:   1,
            AVLinearPCMBitDepthKey:  16,
            AVLinearPCMIsFloatKey:   false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let outFile = try AVAudioFile(forWriting: url, settings: fileFmt)

        // monoFormat 用于手动混声道（若硬件是多声道）
        let monoFmt = AVAudioFormat(
            commonFormat: hwFmt.commonFormat,
            sampleRate:   hwFmt.sampleRate,
            channels:     1,
            interleaved:  hwFmt.isInterleaved
        )

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFmt) { [weak self] buffer, _ in
            guard let self, !self.isPaused else { return }
            let toWrite: AVAudioPCMBuffer
            if buffer.format.channelCount <= 1 {
                toWrite = buffer
            } else if let mono = Self.mixToMono(buffer, targetFormat: monoFmt) {
                toWrite = mono
            } else {
                toWrite = buffer   // 写入失败降级：直接写原始（ffmpeg 会处理）
            }
            try? outFile.write(from: toWrite)
        }

        try engine.start()
        return (engine, outFile)
    }

    /// 多声道混为单声道（float32 平均法）
    private static func mixToMono(_ buf: AVAudioPCMBuffer,
                                   targetFormat: AVAudioFormat?) -> AVAudioPCMBuffer? {
        guard
            let fmt = targetFormat,
            let mono = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: buf.frameLength),
            let dst  = mono.floatChannelData?[0],
            let src  = buf.floatChannelData
        else { return nil }

        mono.frameLength = buf.frameLength
        let chCount = Int(buf.format.channelCount)
        let frames  = Int(buf.frameLength)
        let scale   = Float(1.0 / Double(chCount))
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<chCount { sum += src[c][f] }
            dst[f] = sum * scale
        }
        return mono
    }

    // MARK: - Private: helpers

    private static func deviceNativeSampleRate() -> Double {
        let engine = AVAudioEngine()
        let sr = engine.inputNode.inputFormat(forBus: 0).sampleRate
        return sr > 0 ? sr : 48_000.0
    }
}
