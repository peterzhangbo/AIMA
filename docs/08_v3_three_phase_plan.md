# MeetingSummaryApp V3 三期规划

## 总体拆分

### V3.1 系统能力版

目标：

1. 任务队列
2. 历史记录
3. transcript / summary 版本化
4. 上一个会议处理时可继续录下一个会议

### V3.2 体验增强版

目标：

1. 悬浮录音浮层
2. 主窗口 / 浮层切换
3. transcript 点击回放
4. transcript 编辑
5. 播放联动高亮

### V3.3 环境内聚版

目标：

1. 内置 Python runtime
2. 内置 ffmpeg / ffprobe
3. 内置除模型外的所有依赖
4. 模型检查与下载引导

## 约束

1. 继续沿用 SwiftUI 原生路线，不切 Tauri
2. 先做系统能力，再做体验层，再做交付层
3. 每期结束都必须保持端到端可运行
