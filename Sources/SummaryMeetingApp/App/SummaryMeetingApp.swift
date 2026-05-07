import SwiftUI
import AppKit

@main
struct SummaryMeetingApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        // 单例主窗口：openWindow(id:) 只唤起现有窗口，不会重复创建。
        Window("会议助手", id: "main") {
            RootView(app: appState)
                .frame(minWidth: 900, minHeight: 620)
                .onChange(of: appState.coordinator.state) { _, new in
                    if case .recording = new { Self.hideMainWindow() }
                }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarPanel(
                coordinator: appState.coordinator,
                history: appState.history
            )
        } label: {
            MenuBarIcon(coordinator: appState.coordinator)
        }
        .menuBarExtraStyle(.window)
    }

    static func hideMainWindow() {
        for w in NSApp.windows where w.identifier?.rawValue == "main" {
            w.orderOut(nil)
        }
    }
}

// MARK: - 录制中迷你横幅（在历史/详情页顶部显示，方便录制中查看历史会议）
struct RecordingMiniBanner: View {
    @Bindable var coordinator: RecordingCoordinator
    let onResumeRecordingView: () -> Void
    @State private var now: Date = .init()
    @State private var ticker: Timer?

    var body: some View {
        HStack(spacing: 10) {
            statusDot
            Text(stateLabel).font(.callout.weight(.medium))
            Text(formatDuration(coordinator.elapsedSeconds(at: now)))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            switch coordinator.state {
            case .recording:
                Button("暂停") { coordinator.pause(); now = Date() }
                    .buttonStyle(.bordered).controlSize(.small)
            case .paused:
                Button("继续") { coordinator.resume(); now = Date() }
                    .buttonStyle(.bordered).controlSize(.small)
            default: EmptyView()
            }
            switch coordinator.state {
            case .recording, .paused:
                Button(role: .destructive) {
                    Task { await coordinator.stopAndProcess() }
                } label: { Text("停止并处理") }
                .buttonStyle(.borderedProminent).controlSize(.small)
            default: EmptyView()
            }
            Button {
                onResumeRecordingView()
            } label: {
                Label("录制详情", systemImage: "waveform")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(Divider(), alignment: .bottom)
        .onAppear {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                now = Date()
            }
        }
        .onDisappear { ticker?.invalidate() }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch coordinator.state {
        case .recording:
            Circle().fill(.red).frame(width: 8, height: 8)
        case .paused:
            Circle().fill(.orange).frame(width: 8, height: 8)
        default:
            Circle().fill(.gray).frame(width: 8, height: 8)
        }
    }

    private var stateLabel: String {
        switch coordinator.state {
        case .preparing:    return "准备中"
        case .recording:    return "录制中"
        case .paused:       return "已暂停"
        case .stopping:     return "停止中…"
        default:            return ""
        }
    }

    private func formatDuration(_ s: TimeInterval) -> String {
        let total = Int(max(s, 0))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

// MARK: - AppState

@MainActor
@Observable
final class AppState {
    enum Screen { case permissions, main, recording }
    var screen: Screen = .permissions
    let permissions = PermissionsModel()
    let store: MeetingStore
    let history: HistoryModel
    let coordinator: RecordingCoordinator

    init() {
        let db = MeetingStore.defaultDBURL()
        let store = (try? MeetingStore(dbURL: db)) ?? {
            fatalError("无法初始化数据库于 \(db.path)")
        }()
        self.store = store
        self.history = HistoryModel(store: store)
        self.coordinator = RecordingCoordinator(store: store)
    }
}

// MARK: - RootView

struct RootView: View {
    @Bindable var app: AppState

    var body: some View {
        switch app.screen {
        case .permissions:
            PermissionsView(model: app.permissions) {
                app.screen = .main
            }
        case .main:
            MainSplitView(
                history: app.history,
                store: app.store,
                coordinator: app.coordinator,
                onNewRecording: { app.screen = .recording },
                onResumeRecordingView: { app.screen = .recording }
            )
        case .recording:
            RecordingView(coordinator: app.coordinator, onDone: {
                app.history.reload()
                if let id = app.coordinator.lastCompletedMeetingID {
                    app.history.selectedID = id
                }
                app.screen = .main
            })
        }
    }
}

// MARK: - MainSplitView

struct MainSplitView: View {
    @Bindable var history: HistoryModel
    let store: MeetingStore
    let coordinator: RecordingCoordinator
    let onNewRecording: () -> Void
    let onResumeRecordingView: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            recordingBanner
            splitView
        }
    }

    @ViewBuilder
    private var recordingBanner: some View {
        let isRecording: Bool = {
            switch coordinator.state {
            case .recording, .paused, .preparing, .stopping: return true
            default: return false
            }
        }()
        if isRecording {
            RecordingMiniBanner(coordinator: coordinator,
                                onResumeRecordingView: onResumeRecordingView)
        }
    }

    private var isRecordingActive: Bool {
        switch coordinator.state {
        case .recording, .paused, .preparing, .stopping: return true
        default: return false
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            // onNewRecording 与 onResumeRecordingView 当前实现相同（都切到 .recording 屏），
            // 但语义不同：保留一个回调 + isRecordingActive 控制 label/icon 即可。
            HistorySidebar(model: history,
                           coordinator: coordinator,
                           onNewRecording: onNewRecording,
                           isRecordingActive: isRecordingActive)
        } detail: {
            if let id = history.selectedID,
               let meeting = history.meetings.first(where: { $0.id == id }) {
                MeetingDetailView(meeting: meeting, store: store, coordinator: coordinator,
                                  onReloadHistory: { history.reload() })
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 52))
                        .foregroundStyle(.blue.opacity(0.7))
                    Button(action: isRecordingActive ? onResumeRecordingView : onNewRecording) {
                        Label(isRecordingActive ? "返回录制" : "开始新录制",
                              systemImage: isRecordingActive ? "waveform" : "record.circle")
                            .font(.title3.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isRecordingActive ? .red : .blue)
                    .controlSize(.large)
                    Text("或从左侧选择历史会议")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            history.reload()
            // 崩溃恢复：续跑上次中断的任务
            Task {
                await coordinator.resumePendingTasks()
                history.reload()
            }
        }
        // 录制状态回到 idle 时刷新
        .onChange(of: coordinator.state) { _, newState in
            if case .idle = newState { history.reload() }
        }
        // 后台流水线推进 / 队列变化时刷新（queued → processing → completed 等）
        .onChange(of: coordinator.pipelineTick) { _, _ in
            history.reload()
        }
    }
}
