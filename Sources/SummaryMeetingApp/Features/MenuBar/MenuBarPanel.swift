import SwiftUI

/// Menu Bar 弹出面板：快速开始/停止录制，不需要打开主窗口。
struct MenuBarPanel: View {
    @Bindable var coordinator: RecordingCoordinator
    @Bindable var history: HistoryModel
    @Environment(\.openWindow) private var openWindow
    @State private var now = Date()
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            controls
            Divider()
            footer
        }
        .frame(width: 280)
        .onReceive(timer) { now = $0 }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .overlay {
                    if isRecording {
                        Circle().stroke(statusColor.opacity(0.4), lineWidth: 3)
                            .scaleEffect(1.8)
                            .animation(.easeInOut(duration: 0.8).repeatForever(), value: isRecording)
                    }
                }

            Text(statusLabel)
                .font(.system(.callout, design: .rounded).weight(.medium))

            Spacer()

            if isRecording || isPaused {
                Text(formatDuration(coordinator.elapsedSeconds(at: now)))
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            switch coordinator.state {
            case .idle, .failed:
                Button(action: { Task { await coordinator.start() } }) {
                    Label("开始录制", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

            case .recording:
                Button(action: { coordinator.pause() }) {
                    Label("暂停", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: { Task { await coordinator.stopAndProcess() } }) {
                    Label("停止", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

            case .paused:
                Button(action: { coordinator.resume() }) {
                    Label("继续", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: { Task { await coordinator.stopAndProcess() } }) {
                    Label("停止", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

            case .preparing:
                ProgressView().controlSize(.small)
                Text("准备中...").foregroundStyle(.secondary).font(.callout)
                Spacer()

            case .stopping:
                ProgressView().controlSize(.small)
                Text("停止中...").foregroundStyle(.secondary).font(.callout)
                if let stage = coordinator.processingStage {
                    processingRow(stage)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func processingRow(_ stage: ProcessingStage) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(stageLabel(stage))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("打开主窗口") {
                // 优先唤起已存在的主窗口（可能已最小化到 Dock），避免创建多个。
                let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })
                if let w = main {
                    if w.isMiniaturized { w.deminiaturize(nil) }
                    w.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(id: "main")
                }
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)

            Spacer()

            // 排错入口：把 ~/Library/Logs/AIMA 在 Finder 里展开，方便用户把日志发给我们。
            Button {
                LogCapture.revealLogsInFinder()
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("打开日志文件夹")

            Text("\(history.meetings.count) 条记录")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private var isRecording: Bool {
        if case .recording = coordinator.state { return true }
        return false
    }
    private var isPaused: Bool {
        if case .paused = coordinator.state { return true }
        return false
    }

    private var statusColor: Color {
        switch coordinator.state {
        case .recording:          return .red
        case .paused:             return .orange
        case .failed:             return .gray
        case .preparing:          return .yellow
        case .stopping:           return .yellow
        case .idle:
            if coordinator.activeProcessingMeetingID != nil
                || !coordinator.queuedMeetingIDs.isEmpty { return .blue }
            return .green
        }
    }

    private var statusLabel: String {
        switch coordinator.state {
        case .idle:
            if let stage = coordinator.activeProcessingStage {
                let queued = coordinator.queuedMeetingIDs.count
                let suffix = queued > 0 ? "（队列 \(queued)）" : ""
                return "\(stageLabel(stage))\(suffix)"
            }
            return "就绪"
        case .preparing:     return "准备中"
        case .recording:     return "录制中"
        case .paused:        return "已暂停"
        case .stopping:      return coordinator.processingStage.map { stageLabel($0) } ?? "停止中"
        case .failed(let m): return "失败: \(m.prefix(20))"
        }
    }

    private func stageLabel(_ stage: ProcessingStage) -> String {
        switch stage {
        case .savingAudio:    return "保存音频"
        case .transcribing:   return "转写中 (Whisper)"
        case .diarizing:      return "说话人分离"
        case .parsingTranscript: return "解析转写"
        case .summarizing:    return "生成纪要 (Gemma)"
        case .completed:      return "处理完成"
        case .failed:         return "处理失败"
        }
    }

    private func formatDuration(_ s: TimeInterval) -> String {
        let t = Int(s)
        let h = t / 3600; let m = (t % 3600) / 60; let sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%02d:%02d", m, sec)
    }
}
