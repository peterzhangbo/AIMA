import SwiftUI

@main
struct SummaryMeetingApp: App {
    var body: some Scene {
        WindowGroup("会议纪要") {
            RootView()
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowResizability(.contentSize)
    }
}

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

struct RootView: View {
    @State private var app = AppState()

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
                onNewRecording: { app.screen = .recording }
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

struct MainSplitView: View {
    @Bindable var history: HistoryModel
    let store: MeetingStore
    let onNewRecording: () -> Void

    var body: some View {
        NavigationSplitView {
            HistorySidebar(model: history, onNewRecording: onNewRecording)
        } detail: {
            if let id = history.selectedID, let meeting = history.meetings.first(where: { $0.id == id }) {
                MeetingDetailView(meeting: meeting, store: store)
            } else {
                Button(action: onNewRecording) {
                    VStack(spacing: 14) {
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 52))
                            .foregroundStyle(.secondary)
                        Text("点击开始新录制")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("或从左侧选择历史会议")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { history.reload() }
    }
}
