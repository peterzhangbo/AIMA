import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting
    let store: MeetingStore
    @State private var tab: Tab = .summary
    @State private var transcript: Transcript?
    @State private var speakerSegments: [SpeakerSegment]?   // 多人稿（可能为 nil）
    @State private var summaryMarkdown: String?
    @State private var loadError: String?

    enum Tab: String, CaseIterable, Identifiable {
        case summary    = "纪要"
        case multispk   = "多人稿"
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
            case .recording:  return ("录制中", .red)
            case .processing: return ("处理中", .orange)
            case .completed:  return ("已完成", .green)
            case .failed:     return ("失败",    .gray)
            }
        }()
        Text(label)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let err = loadError {
                    Text(err).foregroundStyle(.orange).font(.callout)
                }
                switch tab {
                case .summary:
                    if let md = summaryMarkdown {
                        MarkdownText(raw: md)
                    } else {
                        Text("暂无纪要").foregroundStyle(.secondary)
                    }

                case .multispk:
                    if let segs = speakerSegments, !segs.isEmpty {
                        multiSpeakerView(segs)
                    } else {
                        Text("暂无多人逐字稿（可能未配置 HF_TOKEN 或 pyannote 未安装）")
                            .foregroundStyle(.secondary)
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

    @ViewBuilder
    private func multiSpeakerView(_ segs: [SpeakerSegment]) -> some View {
        // 为每个说话人分配固定颜色
        let speakers = Array(Set(segs.map(\.speaker))).sorted()
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .mint]
        let colorMap = Dictionary(uniqueKeysWithValues: speakers.enumerated().map { i, s in
            (s, palette[i % palette.count])
        })

        ForEach(segs) { seg in
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(timecode(seg.start))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text(shortSpeaker(seg.speaker))
                        .font(.caption.bold())
                        .foregroundStyle(colorMap[seg.speaker] ?? .primary)
                }
                .frame(width: 64, alignment: .leading)

                Text(seg.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Load

    private func load() {
        loadError = nil
        transcript = nil
        speakerSegments = nil
        summaryMarkdown = nil

        // 纪要
        if let v = try? store.latestSummary(meetingID: meeting.id),
           let text = try? String(contentsOfFile: v.path, encoding: .utf8) {
            summaryMarkdown = text
        }
        // 多人稿（clean）
        if let v = try? store.latestTranscript(meetingID: meeting.id, kind: "multispk_clean") {
            speakerSegments = try? TranscriptMerger.load(from: URL(fileURLWithPath: v.path))
        }
        // 单人稿（raw Whisper）
        if let v = try? store.latestTranscript(meetingID: meeting.id, kind: "raw") {
            transcript = try? WhisperRunner.parseTranscript(jsonURL: URL(fileURLWithPath: v.path))
        } else if let v = try? store.latestTranscript(meetingID: meeting.id) {
            transcript = try? WhisperRunner.parseTranscript(jsonURL: URL(fileURLWithPath: v.path))
        }
    }

    // MARK: Helpers

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

    /// "SPEAKER_00" → "S00"，其余原样
    private func shortSpeaker(_ s: String) -> String {
        if s.hasPrefix("SPEAKER_") {
            return "S" + s.dropFirst("SPEAKER_".count)
        }
        return s
    }
}
