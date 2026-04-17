# MeetingSummaryApp V3.1 架构设计

## 目标

V3.1 解决三个问题：

1. 录音与处理解耦
2. 历史会议可查询
3. transcript / summary 具备版本化能力

## 数据层

### SQLite 表

#### meetings

记录每次会议的主索引：

1. `id`
2. `title`
3. `status`
4. `directory_path`
5. `audio_path`
6. `duration_seconds`
7. `created_at`
8. `updated_at`
9. `current_transcript_version`
10. `current_summary_version`
11. `error_message`

#### transcript_versions

记录当前可用 transcript 版本：

1. `meeting_id`
2. `version`
3. `kind`
4. `json_path`
5. `markdown_path`
6. `created_at`

#### summary_versions

记录会议纪要版本：

1. `meeting_id`
2. `version`
3. `source_transcript_version`
4. `markdown_path`
5. `created_at`

## 服务层

### Recorder

负责：

1. 开始录音
2. 停止录音
3. 生成音频文件

### Processor

负责：

1. Whisper
2. diarization
3. merge / clean
4. Gemma

### Queue

负责：

1. 录音结束后把会议放入队列
2. 顺序处理待处理会议
3. 状态写回 SQLite

## UI 层

### 录音控制台

负责：

1. 当前录音
2. 开始 / 停止
3. 正在处理数量

### 历史列表

负责：

1. 展示所有会议
2. 按最近更新时间排序

### 详情页

负责：

1. 展示当前 transcript 版本
2. 展示当前 summary 版本
3. 触发重新生成纪要
