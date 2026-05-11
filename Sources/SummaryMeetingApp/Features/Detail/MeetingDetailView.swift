import SwiftUI
import AppKit

struct MeetingDetailView: View {
    let meeting: Meeting
    let store: MeetingStore
    let coordinator: RecordingCoordinator
    var onReloadHistory: (() -> Void)? = nil

    @State private var tab: Tab = .summary
    @State private var transcript: Transcript?
    @State private var transcriptURL: URL?
    @State private var speakerSegments: [SpeakerSegment]?
    @State private var speakerSegmentsURL: URL?
    @State private var multiSpeakerVersions: [TranscriptVersion] = []
    @State private var selectedMultiSpeakerVersionID: Int64? = nil
    @State private var summaryVersions: [SummaryVersion] = []
    @State private var selectedVersionID: Int64? = nil
    @State private var summaryMarkdown: String?
    @State private var loadError: String?
    @State private var isRerunning = false
    // 用于检测"版本计数增加 → 自动切到最新"。
    @State private var lastSummaryCount: Int = 0
    @State private var lastMultiSpkCount: Int = 0

    // 逐字稿编辑
    @State private var editingSegmentID: Int?
    @State private var editText: String = ""

    // 多人稿编辑（按索引定位，因为增删会使 id 失效）
    @State private var editingSpeakerIndex: Int?
    @State private var speakerEditText: String = ""
    @State private var renamingSpeakerRaw: String?
    @State private var renameText: String = ""
    // 新增发言人
    @State private var addingSpeakerForIndex: Int?
    @State private var newSpeakerName: String = ""

    // 音频回放
    @State private var audioPlayer = AudioPlayer()

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
            tabBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let path = meeting.audioPath, !path.isEmpty {
                Divider()
                audioBar
            }
        }
        .onAppear(perform: load)
        .onDisappear { audioPlayer.cleanup() }
        .onChange(of: meeting.id) { _, _ in load() }
        // 同一条 meeting 在后台处理/崩溃恢复后就地更新（status、audioPath、durationMs 变化）
        // 也需要重新加载 summary / transcript / audio
        .onChange(of: meeting.status) { _, _ in load() }
        .onChange(of: meeting.audioPath ?? "") { _, _ in load() }
        .onChange(of: selectedVersionID) { _, id in loadSummary(versionID: id) }
        // 后台流水线推进（含 rerun 完成）会 bump pipelineTick；这里对当前会议刷新版本，
        // 并在新版本出现时把筛选器切到最新。
        .onChange(of: coordinator.pipelineTick) { _, _ in reloadVersionsAndJumpLatest() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title).font(.title2.bold())
                    HStack(spacing: 12) {
                        Text(meeting.createdAt, format: .dateTime.year().month().day().hour().minute())
                            .foregroundStyle(.secondary)
                        if meeting.durationMs > 0 {
                            Text("时长 " + formatDuration(Double(meeting.durationMs) / 1000))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                headerStatusAndRetry
            }
            if let reason = meeting.failureReason {
                Text(reason).foregroundStyle(.red).font(.callout)
            }
            if let err = loadError {
                Text(err).foregroundStyle(.orange).font(.callout)
            }
        }
        .padding(16)
    }

    /// 头部右侧：会议状态徽标；失败时附带"重试处理"按钮
    @ViewBuilder
    private var headerStatusAndRetry: some View {
        HStack(spacing: 8) {
            statusBadge
            if meeting.status == .failed {
                Button {
                    Task {
                        isRerunning = true
                        await coordinator.retryProcessing(for: meeting.id)
                        onReloadHistory?()
                        selectedVersionID = nil
                        tab = .summary
                        load()
                        isRerunning = false
                    }
                } label: {
                    Label("重试处理", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(isRerunning)
            }
        }
    }

    // MARK: Tab bar + version picker

    private var tabBar: some View {
        HStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .padding(.leading, 12)

            Spacer()

            // 纪要 Tab：版本 → 重新生成纪要 → 复制（各 8px 间距）
            if tab == .summary {
                if summaryVersions.count > 1 {
                    Picker("版本", selection: $selectedVersionID) {
                        ForEach(summaryVersions) { v in
                            Text(versionLabel(v)).tag(Optional(v.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                    Spacer().frame(width: 8)
                }

                if meeting.status == .completed || isRerunning {
                    Button {
                        Task {
                            isRerunning = true
                            // rerunSummary 现在只是入列，立刻返回；版本切换交由
                            // .onChange(coordinator.pipelineTick) → reloadVersionsAndJumpLatest 处理
                            await coordinator.rerunSummary(for: meeting.id)
                            onReloadHistory?()
                            isRerunning = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isRerunning {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text(isRerunning ? "生成中…" : "重新生成纪要")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRerunning)
                    Spacer().frame(width: 8)
                }

                Button {
                    copyCurrentSummary()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled((summaryMarkdown ?? "").isEmpty)
                .padding(.trailing, 12)
            }

            // 多人稿 Tab：版本（在左）→ 保存版本（在右），8px 间距
            if tab == .multispk {
                if multiSpeakerVersions.count > 1 {
                    Picker("版本", selection: $selectedMultiSpeakerVersionID) {
                        ForEach(multiSpeakerVersions) { v in
                            Text(multiSpeakerVersionLabel(v)).tag(Optional(v.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 180)
                    Spacer().frame(width: 8)
                }

                Button {
                    saveMultiSpeakerVersion()
                } label: {
                    Label("保存版本", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(speakerSegments?.isEmpty ?? true)
                .padding(.trailing, 12)
            }
        }
        .padding(.vertical, 8)
        .onChange(of: selectedMultiSpeakerVersionID) { _, id in
            loadMultiSpeaker(versionID: id)
        }
    }

    private func copyCurrentSummary() {
        guard let md = summaryMarkdown, !md.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
                        // 过滤空段落，按开始时间升序排列
                        let cleaned = t.segments
                            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                            .sorted { $0.start < $1.start }
                        transcriptView(cleaned)
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

    // MARK: Transcript（可点击跳转 + 双击编辑）

    @ViewBuilder
    private func transcriptView(_ segments: [TranscriptSegment]) -> some View {
        ForEach(Array(segments.enumerated()), id: \.element.id) { idx, seg in
            let isActive = audioPlayer.duration > 0
                && audioPlayer.currentTime >= seg.start
                && audioPlayer.currentTime < seg.end
            HStack(alignment: .top, spacing: 10) {
                // 时间码按钮 → seek
                Button {
                    audioPlayer.seek(to: seg.start)
                    if !audioPlayer.isPlaying { audioPlayer.play() }
                } label: {
                    Text(timecode(seg.start))
                        .font(.caption.monospaced())
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                        .frame(width: 52, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("点击跳转播放")

                // 正文：编辑中显示 TextField，否则 Text（双击进入编辑）
                if editingSegmentID == seg.id {
                    TextField("", text: $editText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .fixedSize(horizontal: false, vertical: true)
                        .onSubmit { saveTranscriptEdit(segmentID: seg.id) }
                        .onExitCommand { editingSegmentID = nil }
                } else {
                    Text(seg.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture(count: 2) {
                            editingSegmentID = seg.id
                            editText = seg.text
                        }
                        .help("双击编辑")
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    // MARK: Multi-speaker

    @ViewBuilder
    private func multiSpeakerView(_ segs: [SpeakerSegment]) -> some View {
        let speakers = Array(Set(segs.map(\.speaker))).sorted()
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .mint]
        let colorMap = Dictionary(uniqueKeysWithValues: speakers.enumerated().map { i, s in
            (s, palette[i % palette.count])
        })
        ForEach(Array(segs.enumerated()), id: \.offset) { idx, seg in
            let isActive = audioPlayer.duration > 0
                && audioPlayer.currentTime >= seg.start
                && audioPlayer.currentTime < seg.end
            HStack(alignment: .top, spacing: 10) {
                // 时间码 + 说话人名（双击重命名）
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        audioPlayer.seek(to: seg.start)
                        if !audioPlayer.isPlaying { audioPlayer.play() }
                    } label: {
                        Text(timecode(seg.start))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("点击跳转播放")

                    Text(shortSpeaker(seg.speaker))
                        .font(.caption.bold())
                        .foregroundStyle(colorMap[seg.speaker] ?? .primary)
                        .onTapGesture(count: 2) {
                            renamingSpeakerRaw = seg.speaker
                            renameText = seg.speaker
                        }
                        .contextMenu {
                            Button("批量重命名该说话人") {
                                renamingSpeakerRaw = seg.speaker
                                renameText = seg.speaker
                            }
                        }
                        .help("双击 / 右键批量重命名该说话人")
                }
                .frame(width: 80, alignment: .leading)

                // 正文：编辑中显示 TextField（允许换行作为拆分点），否则 Text
                if editingSpeakerIndex == idx {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("", text: $speakerEditText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .fixedSize(horizontal: false, vertical: true)
                            .onSubmit { saveSpeakerEdit(idx: idx) }
                            .onExitCommand { editingSpeakerIndex = nil }
                        Text("回车保存 · 文本中插入换行会在该处拆分段落")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(seg.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture(count: 2) {
                            editingSpeakerIndex = idx
                            speakerEditText = seg.text
                        }
                        .contextMenu {
                            Button("编辑内容") {
                                editingSpeakerIndex = idx
                                speakerEditText = seg.text
                            }
                            Button("拆分段落") { splitSpeakerSegment(idx: idx) }
                                .disabled(seg.text.count < 2)
                            Button("合并到上一段") { mergeWithPrev(idx: idx) }
                                .disabled(idx == 0)
                            Divider()
                            Menu("切换为已有发言人") {
                                ForEach(speakers.filter { $0 != seg.speaker }, id: \.self) { name in
                                    Button(shortSpeaker(name)) {
                                        switchSpeakerOfSegment(idx: idx, to: name)
                                    }
                                }
                            }
                            .disabled(speakers.filter { $0 != seg.speaker }.isEmpty)
                            Button("新增发言人…") {
                                addingSpeakerForIndex = idx
                                newSpeakerName = ""
                            }
                        }
                        .help("双击编辑 · 右键更多操作")
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(isActive ? Color.accentColor.opacity(0.10) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .sheet(isPresented: Binding(
            get: { renamingSpeakerRaw != nil },
            set: { if !$0 { renamingSpeakerRaw = nil } }
        )) {
            renameSpeakerSheet
        }
        .sheet(isPresented: Binding(
            get: { addingSpeakerForIndex != nil },
            set: { if !$0 { addingSpeakerForIndex = nil } }
        )) {
            addSpeakerSheet
        }
    }

    private var addSpeakerSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新增发言人").font(.headline)
            Text("该段落将归属到这个新的发言人，后续可在其他段落中继续选用。")
                .font(.callout).foregroundStyle(.secondary)
            TextField("发言人名称（例如：李四）", text: $newSpeakerName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { addingSpeakerForIndex = nil }
                Button("确定") { commitAddSpeaker() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newSpeakerName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var renameSpeakerSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重命名说话人").font(.headline)
            Text("当前：\(renamingSpeakerRaw ?? "")").font(.callout).foregroundStyle(.secondary)
            TextField("新名称（例如：张三）", text: $renameText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { renamingSpeakerRaw = nil }
                Button("保存") { commitRenameSpeaker() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    // MARK: Audio bar

    private var audioBar: some View {
        HStack(spacing: 12) {
            Button(action: audioPlayer.togglePlayPause) {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)

            Text(timecode(audioPlayer.currentTime))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            Slider(
                value: Binding(
                    get: { audioPlayer.progress },
                    set: { audioPlayer.seek(to: $0 * audioPlayer.duration) }
                )
            )
            .disabled(audioPlayer.duration == 0)

            Text(timecode(audioPlayer.duration))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Status badge

    @ViewBuilder
    private var statusBadge: some View {
        let (label, color): (String, Color) = {
            // 优先用流水线 progressInfo 给出明确阶段/排队信息
            if let info = coordinator.progressInfo(for: meeting.id) {
                switch info.kind {
                case .processing(let stage):
                    var s = "处理中 · \(ProcessingDisplay.stageLabel(stage))"
                    if let eta = info.etaSeconds { s += " · 剩余约 \(ProcessingDisplay.formatETA(eta))" }
                    return (s, .orange)
                case .queued(let ahead):
                    let pos = ahead == 0 ? "下一个" : "前面 \(ahead) 个"
                    var s = "排队中（\(pos)）"
                    if let eta = info.etaSeconds { s += " · 约 \(ProcessingDisplay.formatETA(eta))" }
                    return (s, .blue)
                }
            }
            switch meeting.status {
            case .recording:  return ("录制中", .red)
            case .queued:     return ("排队中", .blue)
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


    // MARK: Load

    private func load() {
        loadError = nil
        transcript = nil
        transcriptURL = nil
        speakerSegments = nil
        summaryMarkdown = nil
        editingSegmentID = nil

        // 所有纪要版本
        summaryVersions = (try? store.allSummaryVersions(meetingID: meeting.id)) ?? []
        if selectedVersionID == nil || !summaryVersions.contains(where: { $0.id == selectedVersionID }) {
            selectedVersionID = summaryVersions.last?.id   // 默认最新版本
        }
        lastSummaryCount = summaryVersions.count
        loadSummary(versionID: selectedVersionID)

        // 多人稿版本列表
        multiSpeakerVersions = (try? store.allTranscriptVersions(meetingID: meeting.id, kind: "multispk_clean")) ?? []
        if selectedMultiSpeakerVersionID == nil
            || !multiSpeakerVersions.contains(where: { $0.id == selectedMultiSpeakerVersionID }) {
            selectedMultiSpeakerVersionID = multiSpeakerVersions.last?.id
        }
        lastMultiSpkCount = multiSpeakerVersions.count
        loadMultiSpeaker(versionID: selectedMultiSpeakerVersionID)

        // 逐字稿
        if let v = try? store.latestTranscript(meetingID: meeting.id, kind: "raw") {
            let url = URL(fileURLWithPath: v.path)
            transcriptURL = url
            transcript = try? WhisperRunner.parseTranscript(jsonURL: url)
        } else if let v = try? store.latestTranscript(meetingID: meeting.id) {
            let url = URL(fileURLWithPath: v.path)
            transcriptURL = url
            transcript = try? WhisperRunner.parseTranscript(jsonURL: url)
        }

        // 音频播放器
        if let path = meeting.audioPath, !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            audioPlayer.load(url: URL(fileURLWithPath: path))
        } else {
            audioPlayer.cleanup()
        }
    }

    /// 后台流水线推进时（rerun 完成、补救 diarize 等）刷新版本列表；
    /// 一旦发现纪要或多人稿出现新版本，自动把筛选器切到最新。
    /// 不会触碰逐字稿/音频，避免打断正在阅读/播放的状态。
    private func reloadVersionsAndJumpLatest() {
        // 纪要版本
        let newSummaries = (try? store.allSummaryVersions(meetingID: meeting.id)) ?? []
        let summaryGrew = newSummaries.count > lastSummaryCount
        summaryVersions = newSummaries
        lastSummaryCount = newSummaries.count
        if summaryGrew, let latest = newSummaries.last {
            selectedVersionID = latest.id   // 触发 .onChange → loadSummary
        } else if selectedVersionID == nil || !newSummaries.contains(where: { $0.id == selectedVersionID }) {
            selectedVersionID = newSummaries.last?.id
        }

        // 多人稿版本
        let newMultiSpk = (try? store.allTranscriptVersions(meetingID: meeting.id, kind: "multispk_clean")) ?? []
        let multiGrew = newMultiSpk.count > lastMultiSpkCount
        multiSpeakerVersions = newMultiSpk
        lastMultiSpkCount = newMultiSpk.count
        if multiGrew, let latest = newMultiSpk.last {
            selectedMultiSpeakerVersionID = latest.id
            loadMultiSpeaker(versionID: latest.id)
        } else if selectedMultiSpeakerVersionID == nil
                    || !newMultiSpk.contains(where: { $0.id == selectedMultiSpeakerVersionID }) {
            selectedMultiSpeakerVersionID = newMultiSpk.last?.id
            loadMultiSpeaker(versionID: selectedMultiSpeakerVersionID)
        }
    }

    private func loadSummary(versionID: Int64?) {
        summaryMarkdown = nil
        guard let id = versionID,
              let v = summaryVersions.first(where: { $0.id == id }),
              let text = try? String(contentsOfFile: v.path, encoding: .utf8)
        else { return }
        summaryMarkdown = stripLeadingTitleSection(text)
    }

    /// 隐藏开头的"会议标题"节，从"会议概述"开始展示。
    /// 若找不到会议概述则原样返回。
    private func stripLeadingTitleSection(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        if let startIdx = lines.firstIndex(where: { $0.contains("会议概述") }) {
            return lines[startIdx...].joined(separator: "\n")
        }
        return markdown
    }

    // MARK: Transcript editing

    private func saveTranscriptEdit(segmentID: TranscriptSegment.ID) {
        guard var t = transcript,
              let realIdx = t.segments.firstIndex(where: { $0.id == segmentID }) else {
            editingSegmentID = nil
            return
        }
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { editingSegmentID = nil; return }
        t.segments[realIdx].text = trimmed
        t.text = t.segments.map(\.text).joined(separator: " ")
        transcript = t
        editingSegmentID = nil
        // 落盘逐字稿
        if let url = transcriptURL,
           let data = try? JSONEncoder().encode(t) {
            try? data.write(to: url, options: .atomic)
        }
        // 同步多人稿：用更新后的逐字稿文本重建各说话人段落的 text
        syncSpeakerSegments(from: t)
    }

    /// 逐字稿改动后同步到多人稿：每个 SpeakerSegment 的文本
    /// 重新从时间重叠的 TranscriptSegment 拼接得出。
    private func syncSpeakerSegments(from t: Transcript) {
        guard var segs = speakerSegments else { return }
        let updated: [SpeakerSegment] = segs.map { spk in
            let text = t.segments
                .filter { $0.start < spk.end && $0.end > spk.start }
                .map(\.text)
                .joined(separator: " ")
            guard !text.isEmpty else { return spk }
            var copy = spk
            copy.text = text
            return copy
        }
        segs = updated
        speakerSegments = segs
        persistSpeakerSegments(updated)
    }

    // MARK: Multi-speaker editing

    /// 保存多人稿某段编辑。若文本中含换行，则按换行拆为多段；时间按字符数等比分配。
    private func saveSpeakerEdit(idx: Int) {
        guard var segs = speakerSegments, idx < segs.count else {
            editingSpeakerIndex = nil; return
        }
        let parts = speakerEditText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { editingSpeakerIndex = nil; return }

        let base = segs[idx]
        if parts.count == 1 {
            segs[idx].text = parts[0]
        } else {
            // 按字符比例划分时间区间
            let totalChars = parts.reduce(0) { $0 + $1.count }
            let span = max(base.end - base.start, 0.1)
            var cursor = base.start
            var newSegs: [SpeakerSegment] = []
            for (i, text) in parts.enumerated() {
                let ratio = totalChars > 0 ? Double(text.count) / Double(totalChars) : 1.0 / Double(parts.count)
                let end = i == parts.count - 1 ? base.end : min(base.end, cursor + span * ratio)
                newSegs.append(SpeakerSegment(
                    id: base.id + i,   // 保证新 id 暂时唯一；后续 renumber 统一
                    start: cursor, end: end, speaker: base.speaker, text: text
                ))
                cursor = end
            }
            segs.replaceSubrange(idx...idx, with: newSegs)
        }
        renumber(&segs)
        speakerSegments = segs
        editingSpeakerIndex = nil
        persistSpeakerSegments(segs)
    }

    /// 右键"拆分段落"：沿用当前文本从中间拆分（按字符数）
    private func splitSpeakerSegment(idx: Int) {
        guard var segs = speakerSegments, idx < segs.count else { return }
        let s = segs[idx]
        let chars = Array(s.text)
        guard chars.count >= 2 else { return }
        // 找最近的空格或标点；没有则居中
        let mid = chars.count / 2
        let breakers: Set<Character> = [" ", "，", ",", "。", ".", "；", ";"]
        var splitAt = mid
        for offset in 0...(chars.count / 2) {
            if mid + offset < chars.count, breakers.contains(chars[mid + offset]) { splitAt = mid + offset + 1; break }
            if mid - offset > 0, breakers.contains(chars[mid - offset]) { splitAt = mid - offset + 1; break }
        }
        let left = String(chars[0..<splitAt]).trimmingCharacters(in: .whitespaces)
        let right = String(chars[splitAt..<chars.count]).trimmingCharacters(in: .whitespaces)
        guard !left.isEmpty, !right.isEmpty else { return }
        let mid_t = s.start + (s.end - s.start) * Double(splitAt) / Double(chars.count)
        let a = SpeakerSegment(id: s.id, start: s.start, end: mid_t, speaker: s.speaker, text: left)
        let b = SpeakerSegment(id: s.id + 1, start: mid_t, end: s.end, speaker: s.speaker, text: right)
        segs.replaceSubrange(idx...idx, with: [a, b])
        renumber(&segs)
        speakerSegments = segs
        persistSpeakerSegments(segs)
    }

    /// 合并到上一段：文本拼接、时间区间取并集、speaker 沿用上一段
    private func mergeWithPrev(idx: Int) {
        guard var segs = speakerSegments, idx > 0, idx < segs.count else { return }
        let cur = segs[idx]
        var prev = segs[idx - 1]
        prev.text = [prev.text, cur.text].joined(separator: " ")
        prev.end = max(prev.end, cur.end)
        segs[idx - 1] = prev
        segs.remove(at: idx)
        renumber(&segs)
        speakerSegments = segs
        persistSpeakerSegments(segs)
    }

    /// 提交说话人重命名：把所有 speaker == renamingSpeakerRaw 的段落 speaker 改为 renameText
    private func commitRenameSpeaker() {
        guard let raw = renamingSpeakerRaw, var segs = speakerSegments else {
            renamingSpeakerRaw = nil; return
        }
        let newName = renameText.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != raw else {
            renamingSpeakerRaw = nil; return
        }
        for i in segs.indices where segs[i].speaker == raw {
            segs[i].speaker = newName
        }
        speakerSegments = segs
        persistSpeakerSegments(segs)
        renamingSpeakerRaw = nil
    }

    /// 将某段切换给已有发言人
    private func switchSpeakerOfSegment(idx: Int, to name: String) {
        guard var segs = speakerSegments, idx < segs.count else { return }
        segs[idx].speaker = name
        speakerSegments = segs
        persistSpeakerSegments(segs)
    }

    /// 新增发言人并将当前段落归属到这个新名字
    private func commitAddSpeaker() {
        defer { addingSpeakerForIndex = nil }
        guard let idx = addingSpeakerForIndex,
              var segs = speakerSegments, idx < segs.count else { return }
        let name = newSpeakerName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        segs[idx].speaker = name
        speakerSegments = segs
        persistSpeakerSegments(segs)
    }

    private func renumber(_ segs: inout [SpeakerSegment]) {
        for i in segs.indices { segs[i].id = i }
    }

    /// 把改动写回当前选中版本的 JSON 文件（即编辑即保存到当前版本）。
    /// 若要保留当前版本不被覆盖，使用「保存版本」按钮另存为新版本。
    private func persistSpeakerSegments(_ segs: [SpeakerSegment]) {
        guard let url = speakerSegmentsURL else { return }
        try? TranscriptMerger.save(segs, to: url)
    }

    private func loadMultiSpeaker(versionID: Int64?) {
        speakerSegments = nil
        speakerSegmentsURL = nil
        guard let id = versionID,
              let v = multiSpeakerVersions.first(where: { $0.id == id }) else { return }
        let url = URL(fileURLWithPath: v.path)
        speakerSegmentsURL = url
        speakerSegments = try? TranscriptMerger.load(from: url)
    }

    /// 把当前工作副本另存为新版本。
    private func saveMultiSpeakerVersion() {
        guard let segs = speakerSegments else { return }
        guard let paths = SessionPaths(meetingID: meeting.id) else { return }
        try? FileManager.default.createDirectory(at: paths.transcriptDir, withIntermediateDirectories: true)
        let ts = Int(Date().timeIntervalSince1970)
        let url = paths.transcriptDir.appendingPathComponent("multispeaker_clean_v\(ts).json")
        do {
            try TranscriptMerger.save(segs, to: url)
            _ = try store.addTranscriptVersion(meetingID: meeting.id, kind: "multispk_clean", path: url)
        } catch {
            loadError = "保存版本失败: \(error.localizedDescription)"
            return
        }
        multiSpeakerVersions = (try? store.allTranscriptVersions(meetingID: meeting.id, kind: "multispk_clean")) ?? []
        selectedMultiSpeakerVersionID = multiSpeakerVersions.last?.id
        loadMultiSpeaker(versionID: selectedMultiSpeakerVersionID)
    }

    private func multiSpeakerVersionLabel(_ v: TranscriptVersion) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        let n = multiSpeakerVersions.firstIndex(where: { $0.id == v.id }).map { $0 + 1 } ?? 1
        return "v\(n)  \(f.string(from: v.createdAt))"
    }

    // MARK: Helpers

    private func versionLabel(_ v: SummaryVersion) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        let n = summaryVersions.firstIndex(where: { $0.id == v.id }).map { $0 + 1 } ?? 1
        return "v\(n)  \(f.string(from: v.createdAt))"
    }

    private func timecode(_ s: Double) -> String {
        let t = Int(max(0, s))
        let h = t / 3600; let m = (t % 3600) / 60; let sec = t % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%02d:%02d", m, sec)
    }

    private func formatDuration(_ s: Double) -> String {
        let t = Int(s); let h = t / 3600; let m = (t % 3600) / 60; let sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private func shortSpeaker(_ s: String) -> String {
        s.hasPrefix("SPEAKER_") ? "S" + s.dropFirst("SPEAKER_".count) : s
    }
}
