import Foundation

/// UI 展示用：把 `ProcessingStage` 和秒数 ETA 转成中文标签。
/// HistorySidebar / MeetingDetailView 共用，避免两处复制不同步。
enum ProcessingDisplay {
    static func stageLabel(_ s: ProcessingStage) -> String {
        switch s {
        case .savingAudio:       return "保存音频"
        case .transcribing:      return "转写"
        case .diarizing:         return "说话人分离"
        case .parsingTranscript: return "解析"
        case .summarizing:       return "生成纪要"
        case .completed:         return "完成"
        case .failed:            return "失败"
        }
    }

    static func formatETA(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        let m = seconds / 60
        let s = seconds % 60
        if m < 60 {
            return s == 0 ? "\(m) 分钟" : "\(m) 分 \(s) 秒"
        }
        return "\(m / 60) 时 \(m % 60) 分"
    }
}
