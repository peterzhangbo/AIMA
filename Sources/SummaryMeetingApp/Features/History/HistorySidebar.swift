import SwiftUI

@MainActor
@Observable
final class HistoryModel {
    var meetings: [Meeting] = []
    var selectedID: MeetingID?
    private let store: MeetingStore

    init(store: MeetingStore) {
        self.store = store
        reload()
    }

    func reload() {
        meetings = (try? store.listMeetings()) ?? []
    }

    func select(_ id: MeetingID) {
        selectedID = id
    }
}

struct HistorySidebar: View {
    @Bindable var model: HistoryModel
    let onNewRecording: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("会议历史").font(.headline)
                Spacer()
                Button {
                    onNewRecording()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("开始新录制")
            }
            .padding(12)

            Divider()

            List(model.meetings, selection: Binding(
                get: { model.selectedID?.raw },
                set: { newVal in
                    if let v = newVal { model.selectedID = MeetingID(v) }
                }
            )) { meeting in
                row(meeting)
                    .tag(meeting.id.raw)
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 240)
    }

    @ViewBuilder
    private func row(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                statusDot(m.status)
                Text(m.title).font(.body).lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(m.createdAt, format: .dateTime.month().day().hour().minute())
                    .foregroundStyle(.secondary)
                    .font(.caption)
                if m.durationMs > 0 {
                    Text(formatDuration(Double(m.durationMs) / 1000))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func statusDot(_ s: MeetingStatus) -> some View {
        let color: Color = {
            switch s {
            case .recording: return .red
            case .processing: return .orange
            case .completed: return .green
            case .failed: return .gray
            }
        }()
        return Circle().fill(color).frame(width: 7, height: 7)
    }

    private func formatDuration(_ s: Double) -> String {
        let total = Int(s)
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}
