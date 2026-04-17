import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting
    let store: MeetingStore
    @State private var tab: Tab = .summary
    @State private var transcript: Transcript?
    @State private var summaryMarkdown: String?
    @State private var loadError: String?

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "纪要"
        case transcript = "逐字稿"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .padding(12)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear(perform: load)
        .onChange(of: meeting.id) { _, _ in load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title).font(.title2.bold())
            HStack(spacing: 12) {
                Text(meeting.createdAt, format: .dateTime.year().month().day().hour().minute())
                    .foregroundStyle(.secondary)
                if meeting.durationMs > 0 {
                    Text("时长 " + formatDuration(Double(meeting.durationMs) / 1000))
                        .foregroundStyle(.secondary)
                }
                statusBadge
            }
            if let reason = meeting.failureReason {
                Text(reason).foregroundStyle(.red).font(.callout)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (label, color): (String, Color) = {
            switch meeting.status {
            case .recording: return ("录制中", .red)
            case .processing: return ("处理中", .orange)
            case .completed: return ("已完成", .green)
            case .failed: return ("失败", .gray)
            }
        }()
        Text(label)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let err = loadError {
                    Text(err).foregroundStyle(.red)
                }
                switch tab {
                case .summary:
                    if let md = summaryMarkdown {
                        MarkdownText(raw: md)
                    } else {
                        Text("暂无纪要").foregroundStyle(.secondary)
                    }
                case .transcript:
                    if let t = transcript, !t.segments.isEmpty {
                        ForEach(t.segments) { seg in
                            HStack(alignment: .top, spacing: 10) {
                                Text(timecode(seg.start))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .leading)
                                Text(seg.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else if let t = transcript {
                        Text(t.text).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("暂无转写").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func load() {
        loadError = nil
        transcript = nil
        summaryMarkdown = nil
        if let v = try? store.latestSummary(meetingID: meeting.id),
           let text = try? String(contentsOfFile: v.path, encoding: .utf8) {
            summaryMarkdown = text
        }
        if let v = try? store.latestTranscript(meetingID: meeting.id) {
            let url = URL(fileURLWithPath: v.path)
            transcript = try? WhisperRunner.parseTranscript(jsonURL: url)
        }
    }

    private func timecode(_ s: Double) -> String {
        let total = Int(s)
        return String(format: "%02d:%02d", total / 60, total % 60)
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
