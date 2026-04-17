import Foundation
import AVFoundation

public final class MicRecorder: NSObject, @unchecked Sendable {
    private var recorder: AVAudioRecorder?
    public private(set) var outputURL: URL?

    public func start(to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true
        guard rec.prepareToRecord() else {
            throw NSError(domain: "MicRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "prepareToRecord 失败"])
        }
        guard rec.record() else {
            throw NSError(domain: "MicRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "record() 失败"])
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
