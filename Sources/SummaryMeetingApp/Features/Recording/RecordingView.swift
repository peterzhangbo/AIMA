import SwiftUI

struct RecordingView: View {
    @Bindable var coordinator: RecordingCoordinator
    let onDone: () -> Void
    @State private var now: Date = .init()
    @State private var ticker: Timer?

    private var canLeave: Bool {
        // 录制 / 暂停时允许返回历史；录制会在后台继续。
        // 仅在 .preparing / .stopping 这种短暂过渡态禁止离开。
        switch coordinator.state {
        case .preparing, .stopping: return false
        default: return true
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            statusBanner

            Text(formatDuration(coordinator.elapsedSeconds(at: now)))
                .font(.system(size: 64, weight: .semibold, design: .monospaced))
                .monospacedDigit()

            // 固定高度的按钮区，防止切换时布局抖动
            ZStack {
                switch coordinator.state {
                case .idle, .failed:
                    Button {
                        Task { await coordinator.start() }
                    } label: {
                        Label("开始录制", systemImage: "record.circle.fill")
                            .frame(width: 300)
                    }
                    .keyboardShortcut("r")
                case .preparing:
                    ProgressView("准备中…").frame(width: 300)
                case .recording:
                    HStack(spacing: 16) {
                        Button {
                            coordinator.pause()
                            now = Date()
                        } label: {
                            Text("暂停").frame(width: 130)
                        }
                        Button(role: .destructive) {
                            Task { await coordinator.stopAndProcess() }
                        } label: {
                            Label("停止并处理", systemImage: "stop.circle.fill")
                                .frame(width: 150)
                        }
                    }
                case .paused:
                    HStack(spacing: 16) {
                        Button {
                            coordinator.resume()
                            now = Date()
                        } label: {
                            Text("继续").frame(width: 130)
                        }
                        Button(role: .destructive) {
                            Task { await coordinator.stopAndProcess() }
                        } label: {
                            Label("停止并处理", systemImage: "stop.circle.fill")
                                .frame(width: 150)
                        }
                    }
                case .stopping:
                    ProgressView("停止中…").frame(width: 300)
                }
            }
            .frame(height: 44)
            .controlSize(.large)

            if let stage = coordinator.processingStage {
                processingBanner(stage)
            }

            if let err = coordinator.lastError {
                Text(err).foregroundStyle(.red).font(.callout)
                    .multilineTextAlignment(.center)
            }

            if let transcript = coordinator.lastTranscript {
                TranscriptPreview(transcript: transcript)
            }
        }
        .padding(32)
        .frame(minWidth: 640, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    onDone()
                } label: {
                    Label("历史", systemImage: "chevron.left")
                }
                .disabled(!canLeave)
            }
        }
        .onAppear {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                now = Date()
            }
            // 进入页面立即自动开始录制
            Task { await coordinator.start() }
        }
        .onDisappear { ticker?.invalidate() }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch coordinator.state {
        case .idle:
            Text("空闲").foregroundStyle(.secondary)
        case .preparing:
            Text("准备中").foregroundStyle(.secondary)
        case .recording:
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 9, height: 9)
                    .opacity(0.9)
                Text("录制中")
                if coordinator.degraded {
                    Text("· 系统音频已降级").foregroundStyle(.orange).font(.callout)
                }
            }
        case .paused:
            HStack(spacing: 6) {
                Circle().fill(.orange).frame(width: 9, height: 9)
                Text("已暂停")
            }
        case .stopping:
            Text("停止中…").foregroundStyle(.secondary)
        case .failed(let message):
            if message.contains(MicRecorder.noDeviceMessage) {
                noMicCard
            } else {
                Text("失败：\(message)").foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private func processingBanner(_ stage: ProcessingStage) -> some View {
        let (label, done): (String, Bool) = {
            switch stage {
            case .savingAudio:       return ("音频保存中", false)
            case .transcribing:      return ("Whisper 转写中（本地推理，请耐心等待）", false)
            case .diarizing:         return ("说话人分离中（pyannote）", false)
            case .parsingTranscript: return ("解析转写结果", false)
            case .summarizing:       return ("Gemma 生成纪要中（本地推理，请耐心等待）", false)
            case .completed:         return ("处理完成 · 可返回历史查看", true)
            case .failed:            return ("处理失败", true)
            }
        }()
        HStack(spacing: 8) {
            if !done { ProgressView().controlSize(.small) }
            Text(label)
                .foregroundStyle(stage == .failed ? Color.red : stage == .completed ? Color.green : .secondary)
        }
    }

    // MARK: - No Microphone Card

    private var noMicCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 44))
                .foregroundStyle(.red)

            VStack(spacing: 6) {
                Text("未检测到麦克风")
                    .font(.title2.bold())
                Text("系统中没有可用的音频输入设备。\n请按以下步骤排查：")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("检查麦克风是否连接（USB / 3.5mm / 蓝牙）", systemImage: "1.circle.fill")
                Label("MacBook：检查是否被静音或被其它 App 独占", systemImage: "2.circle.fill")
                Label("Mac Mini / Studio：需连接外置麦克风", systemImage: "3.circle.fill")
                Label("打开声音设置，确认「输入」列表不为空", systemImage: "4.circle.fill")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    MicRecorder.openSoundInputSettings()
                } label: {
                    Label("打开声音设置", systemImage: "speaker.wave.2")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await coordinator.start() }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .background(.red.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func formatDuration(_ s: TimeInterval) -> String {
        let total = Int(max(s, 0))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

struct TranscriptPreview: View {
    let transcript: Transcript
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("转写预览").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(transcript.segments) { seg in
                        HStack(alignment: .top, spacing: 8) {
                            Text(timecode(seg.start))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .leading)
                            Text(seg.text)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .padding(8)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
    private func timecode(_ s: Double) -> String {
        String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
