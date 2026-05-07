import Foundation
import AVFoundation

public final class MicRecorder: NSObject, @unchecked Sendable {
    private var recorder: AVAudioRecorder?
    public private(set) var outputURL: URL?

    public func start(to url: URL) throws {
        // 预检 1：TCC 麦克风授权——record() 在未授权时返回 false 但不给原因，先显式检查
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
        if !FileManager.default.isWritableFile(atPath: parent.path) {
            throw NSError(domain: "MicRecorder", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "录音目录不可写：\(parent.path)"])
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let rec: AVAudioRecorder
        do {
            rec = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            throw NSError(domain: "MicRecorder", code: 12,
                          userInfo: [NSLocalizedDescriptionKey:
                            "AVAudioRecorder 创建失败：\(error.localizedDescription)（输出路径 \(url.path)）"])
        }
        rec.isMeteringEnabled = true
        guard rec.prepareToRecord() else {
            throw NSError(domain: "MicRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "prepareToRecord 失败（输出路径 \(url.path)，权限：\(authStatus.rawValue)）"])
        }
        // record() 偶发 false 多半是设备占用/采样率冲突，等 200ms 重试一次
        var ok = rec.record()
        if !ok {
            Thread.sleep(forTimeInterval: 0.2)
            ok = rec.record()
        }
        guard ok else {
            // 最常见：默认麦克风被其它应用独占（如视频会议正在用），或外接设备拔出
            throw NSError(domain: "MicRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                            "record() 启动失败——可能默认麦克风被其它应用占用、外接麦克风断开，或采样率冲突。"
                            + "请关闭其它正在录音/通话的 App 后重试；输出路径 \(url.path)"])
        }
        self.recorder = rec
        self.outputURL = url
    }

    public func stop() {
        recorder?.stop()
        recorder = nil
    }

    public func pause() { recorder?.pause() }
    public func resume() { recorder?.record() }

    public var currentTime: TimeInterval { recorder?.currentTime ?? 0 }

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
}
