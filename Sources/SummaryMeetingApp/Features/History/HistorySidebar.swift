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
    let coordinator: RecordingCoordinator
    let onNewRecording: () -> Void
    var isRecordingActive: Bool = false

    @State private var searchText = ""
    @State private var statusFilter: StatusFilter = .all
    @State private var dateFilter: DateFilter = .all
    @State private var pickedDay: Date = Date()
    @State private var showFilterPopover = false

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all, completed, processing, queued, failed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:        return "全部"
            case .completed:  return "已完成"
            case .processing: return "处理中"
            case .queued:     return "排队中"
            case .failed:     return "失败"
            }
        }
    }

    enum DateFilter: String, CaseIterable, Identifiable {
        case all, today, thisWeek, thisMonth, specificDay
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:         return "全部时间"
            case .today:       return "今天"
            case .thisWeek:    return "本周"
            case .thisMonth:   return "本月"
            case .specificDay: return "指定某天"
            }
        }
    }

    private var activeFilterCount: Int {
        (statusFilter == .all ? 0 : 1) + (dateFilter == .all ? 0 : 1)
    }

    private var filtered: [Meeting] {
        model.meetings.filter { m in
            if !searchText.isEmpty, !m.title.localizedCaseInsensitiveContains(searchText) {
                return false
            }
            if statusFilter != .all, !matchStatus(m.status, statusFilter) { return false }
            if !matchDate(m.createdAt, dateFilter, day: pickedDay) { return false }
            return true
        }
    }

    private func matchStatus(_ s: MeetingStatus, _ f: StatusFilter) -> Bool {
        switch f {
        case .all:        return true
        case .completed:  return s == .completed
        case .processing: return s == .processing || s == .recording
        case .queued:     return s == .queued
        case .failed:     return s == .failed
        }
    }

    private func matchDate(_ d: Date, _ f: DateFilter, day: Date) -> Bool {
        let cal = Calendar.current
        switch f {
        case .all:         return true
        case .today:       return cal.isDateInToday(d)
        case .thisWeek:    return cal.isDate(d, equalTo: Date(), toGranularity: .weekOfYear)
        case .thisMonth:   return cal.isDate(d, equalTo: Date(), toGranularity: .month)
        case .specificDay: return cal.isDate(d, inSameDayAs: day)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("会议历史").font(.headline)
                Spacer()
                Button {
                    onNewRecording()
                } label: {
                    Image(systemName: isRecordingActive ? "waveform.circle.fill" : "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(isRecordingActive ? Color.red : Color.blue)
                }
                .buttonStyle(.borderless)
                .help(isRecordingActive ? "返回录制" : "开始新录制")
            }
            .padding(12)

            // 搜索框 + 筛选
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("搜索会议", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    showFilterPopover.toggle()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "line.3.horizontal.decrease.circle\(activeFilterCount > 0 ? ".fill" : "")")
                            .foregroundStyle(activeFilterCount > 0 ? .blue : .secondary)
                        if activeFilterCount > 0 {
                            Text("\(activeFilterCount)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(2)
                                .background(Circle().fill(.blue))
                                .offset(x: 6, y: -4)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("筛选")
                .popover(isPresented: $showFilterPopover, arrowEdge: .bottom) {
                    filterPopover
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            Divider()

            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: searchText.isEmpty ? "tray" : "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(searchText.isEmpty ? "暂无会议记录" : "无匹配结果")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            } else {
                List(filtered, selection: Binding(
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
        }
        .frame(minWidth: 240)
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("状态").font(.caption).foregroundStyle(.secondary)
                Picker("状态", selection: $statusFilter) {
                    ForEach(StatusFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("时间").font(.caption).foregroundStyle(.secondary)
                Picker("时间", selection: $dateFilter) {
                    ForEach(DateFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                if dateFilter == .specificDay {
                    DatePicker("日期", selection: $pickedDay, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                }
            }

            HStack {
                Button("清除") {
                    statusFilter = .all
                    dateFilter = .all
                }
                .disabled(activeFilterCount == 0)
                Spacer()
                Button("完成") { showFilterPopover = false }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
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
                if let badge = extendedBadge(for: m) {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(statusColor(m.status))
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func statusDot(_ s: MeetingStatus) -> some View {
        Circle().fill(statusColor(s)).frame(width: 7, height: 7)
    }

    private func statusColor(_ s: MeetingStatus) -> Color {
        switch s {
        case .recording:  return .red
        case .queued:     return .blue
        case .processing: return .orange
        case .completed:  return .green
        case .failed:     return .gray
        }
    }

    private func statusBadgeText(_ s: MeetingStatus) -> String? {
        switch s {
        case .recording:  return "● 录制中"
        case .queued:     return "排队中"
        case .processing: return "处理中"
        case .failed:     return "失败"
        case .completed:  return nil
        }
    }

    /// 列表中扩展状态文本：处理中显示阶段+ETA，排队中显示位次+ETA。
    /// 依赖 coordinator.pipelineTick 触发刷新（外层 onChange 已订阅）。
    private func extendedBadge(for m: Meeting) -> String? {
        if let info = coordinator.progressInfo(for: m.id) {
            switch info.kind {
            case .processing(let stage):
                let label = ProcessingDisplay.stageLabel(stage)
                if let eta = info.etaSeconds {
                    return "处理中 · \(label) · 剩余约 \(ProcessingDisplay.formatETA(eta))"
                }
                return "处理中 · \(label)"
            case .queued(let ahead):
                let pos = ahead == 0 ? "下一个" : "前面 \(ahead) 个"
                if let eta = info.etaSeconds {
                    return "排队中（\(pos)）· 约 \(ProcessingDisplay.formatETA(eta))"
                }
                return "排队中（\(pos)）"
            }
        }
        return statusBadgeText(m.status)
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
