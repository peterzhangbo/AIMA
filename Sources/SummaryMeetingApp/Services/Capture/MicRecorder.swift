import Foundation
import AVFoundation

public final class MicRecorder: NSObject, @unchecked Sendable {
    private var recorder: AVAudioRecorder?
    public private(set) var outputURL: URL?

    public func start(to url: URL) throws {
        // 预检 1：TCC 麦克风授权
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard authStatus == .authorized else {
            let label: String = {
                switch authStatus {
                case .notDetermined: return "未请求（请在权限页点击 请求权限 按钮）"
                case .denied:        return "被拒绝（系统设置 → 隐私与安全性 → 麦克风 中重新勾选 AIMA）"
                case .restricted:    return "受限（家长控制/MDM 阻止）"
                default:             return "状态：\(authStatus.rawValue)"
                }
            }()
            throw NSError(domain: "MicRecorder", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "麦克风未授权——\(label)"])
        }

        // 预检 2：父目录可写
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw NSError(domain: "MicRecorder", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "录音目录不可写：\(parent.path)"])
        }

        // 查询设备原生采样率，避免固定 48kHz 与硬件冲突
        let nativeSampleRate = Self.deviceNativeSampleRate()
        print("[MicRecorder] 设备原生采样率：\(nativeSampleRate) Hz")

        // 按优先级依次尝试各种 settings 组合，直到 record() 成功
        let candidates: [[String: Any]] = [
            // 1️⃣ 用设备原生采样率 + 16-bit PCM（最可能成功）
            [AVFormatIDKey: Int(kAudioFormatLinearPCM),
             AVSampleRateKey: nativeSampleRate,
             AVNumberOfChannelsKey: 1,
             AVLinearPCMBitDepthKey: 16,
             AVLinearPCMIsFloatKey: false,
             AVLinearPCMIsBigEndianKey: false],
            // 2️⃣ 原生采样率 + 32-bit float（兼容高端接口设备）
            [AVFormatIDKey: Int(kAudioFormatLinearPCM),
             AVSampleRateKey: nativeSampleRate,
             AVNumberOfChannelsKey: 1,
             AVLinearPCMBitDepthKey: 32,
             AVLinearPCMIsFloatKey: true,
             AVLinearPCMIsBigEndianKey: false],
            // 3️⃣ 固定 44100 Hz + 16-bit（传统通用格式）
            [AVFormatIDKey: Int(kAudioFormatLinearPCM),
             AVSampleRateKey: 44_100.0,
             AVNumberOfChannelsKey: 1,
             AVLinearPCMBitDepthKey: 16,
             AVLinearPCMIsFloatKey: false,
             AVLinearPCMIsBigEndianKey: false],
            // 4️⃣ 降级到 AAC（.m4a），彻底让 AVFoundation 自行协商
            [AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
             AVSampleRateKey: 44_100.0,
             AVNumberOfChannelsKey: 1,
             AVEncoderBitRateKey: 128_000,
             AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue],
        ]

        // 候选 4 是 AAC，需要 .m4a 扩展名
        let m4aURL = url.deletingPathExtension().appendingPathExtension("m4a")

        var lastError: Error?
        for (idx, settings) in candidates.enumerated() {
            let targetURL = idx == candidates.count - 1 ? m4aURL : url
            do {
                let rec = try AVAudioRecorder(url: targetURL, settings: settings)
                rec.isMeteringEnabled = true
                guard rec.prepareToRecord() else {
                    print("[MicRecorder] 候选\(idx+1) prepareToRecord 失败，尝试下一个")
                    continue
                }
                var ok = rec.record()
                if !ok {
                    Thread.sleep(forTimeInterval: 0.2)
                    ok = rec.record()
                }
                if ok {
                    print("[MicRecorder] 候选\(idx+1) 录音成功启动，settings=\(settings)")
                    self.recorder = rec
                    self.outputURL = targetURL
                    return
                } else {
                    print("[MicRecorder] 候选\(idx+1) record() 返回 false，尝试下一个")
                }
            } catch {
                print("[MicRecorder] 候选\(idx+1) 创建失败：\(error.localizedDescription)")
                lastError = error
            }
        }

        // 所有候选均失败
        throw NSError(domain: "MicRecorder", code: 2,
                      userInfo: [NSLocalizedDescriptionKey:
                        "麦克风录音无法启动（已尝试 \(candidates.count) 种格式）。"
                        + "可能原因：其它 App 独占麦克风、外接设备断开或系统音频服务异常。"
                        + "请关闭其它录音/通话 App 后重试。"
                        + (lastError.map { "  底层错误：\($0.localizedDescription)" } ?? "")
                        + "  输出路径：\(url.path)"])
    }

    public func stop() {
        recorder?.stop()
        recorder = nil
    }

    public func pause() { recorder?.pause() }
    public func resume() { recorder?.record() }

    public var currentTime: TimeInterval { recorder?.currentTime ?? 0 }

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

    // MARK: - Private helpers

    /// 通过 AVAudioEngine 查询当前输入设备的原生采样率，失败时退回 48000
    private static func deviceNativeSampleRate() -> Double {
        let engine = AVAudioEngine()
        // inputNode.inputFormat 强制系统报告硬件格式
        let fmt = engine.inputNode.inputFormat(forBus: 0)
        let sr = fmt.sampleRate
        // sampleRate == 0 说明查询失败（如 Sandbox 限制），退回 48000
        return sr > 0 ? sr : 48_000.0
    }
}
