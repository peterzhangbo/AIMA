import Foundation
import AVFoundation
import Observation

/// AVPlayer 封装，供 MeetingDetailView 音频回放使用。
/// 设计为 @Observable 以便 SwiftUI 直接观察 currentTime / isPlaying。
@MainActor
@Observable
final class AudioPlayer {

    // MARK: - Observable state

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying: Bool = false

    /// 0…1，可直接绑定到 Slider
    var progress: Double { duration > 0 ? min(currentTime / duration, 1.0) : 0 }

    // MARK: - Private

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var itemObservations: [NSKeyValueObservation] = []

    // MARK: - API

    func load(url: URL) {
        cleanup()

        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        self.player = p

        // 时长（item 准备好后触发）
        let durObs = item.observe(\.duration, options: [.new, .initial]) { [weak self] item, _ in
            let d = item.duration
            guard d.isValid, !d.isIndefinite, d.seconds > 0 else { return }
            DispatchQueue.main.async { self?.duration = d.seconds }
        }

        // 播放状态
        let stateObs = p.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, _ in
            DispatchQueue.main.async { self?.isPlaying = player.timeControlStatus == .playing }
        }

        itemObservations = [durObs, stateObs]

        // 定时刷新当前时间（0.1 s）
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.currentTime = time.seconds }
        }
    }

    func play()  { player?.play() }
    func pause() { player?.pause() }
    func togglePlayPause() { isPlaying ? pause() : play() }

    /// 跳转到指定秒数（精确 seek，不允许容差）
    func seek(to seconds: Double) {
        guard let player else { return }
        let clamped = max(0, min(seconds, duration))
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        // 50 ms 容差：允许解码器从关键帧跳转，避免压缩格式（AAC/m4a）卡顿
        let tol = CMTime(seconds: 0.05, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: tol, toleranceAfter: tol)
        currentTime = clamped   // 乐观更新，避免 UI 跳闪
    }

    /// 清理资源（切换会议或视图消失时调用）
    func cleanup() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        itemObservations.forEach { $0.invalidate() }
        itemObservations = []
        player?.pause()
        player = nil
        currentTime = 0
        duration = 0
        isPlaying = false
    }
}
