import SwiftUI

/// 菜单栏图标：按协调器状态切换样式，并在录制 / 处理中做轻量动画。
struct MenuBarIcon: View {
    @Bindable var coordinator: RecordingCoordinator
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.hierarchical)
            .onReceive(timer) { _ in phase = (phase &+ 1) % 4 }
    }

    private var iconName: String {
        switch coordinator.state {
        case .recording:
            // 闪烁的红点
            return phase % 2 == 0 ? "record.circle.fill" : "record.circle"
        case .paused:
            return "pause.circle.fill"
        case .preparing:
            return "hourglass"
        case .stopping:
            return phase % 2 == 0 ? "arrow.down.circle" : "arrow.down.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .idle:
            if coordinator.activeProcessingMeetingID != nil
                || !coordinator.queuedMeetingIDs.isEmpty {
                // 处理中：旋转样式的齿轮（靠多图标切换制造动效）
                let spinners = ["gearshape", "gearshape.fill", "gearshape.2", "gearshape.2.fill"]
                return spinners[phase % spinners.count]
            }
            return "waveform.and.mic"
        }
    }
}
