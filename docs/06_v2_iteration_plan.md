# MeetingSummaryApp V2 迭代方案

## 目标

在现有 MVP 基础上新增“多人逐字稿层”，让会议纪要基于多人逐字稿而不是普通 transcript 生成。

## V2 P0 范围

1. 保留当前录音、标准化、Whisper、Gemma 主链
2. 在 Whisper 后增加 pyannote diarization
3. 输出 `transcript_raw.json`
4. 输出 `speaker_diarization_raw.json`
5. 输出 `multi_speaker_transcript_raw.json`
6. 输出 `multi_speaker_transcript.json`
7. 输出 `multi_speaker_transcript.md`
8. 使用 clean 多人逐字稿生成 `meeting_minutes.md`

## 实现策略

### 1. diarization

使用 `pyannote/speaker-diarization-community-1`，优先读取：

- `exclusive_speaker_diarization`

输出统一 JSON 结构：

```json
[
  {
    "speaker": "SPEAKER_00",
    "start": 3.21,
    "end": 9.58
  }
]
```

### 2. merge

采用 `segment overlap max` 规则。

对于每个 Whisper segment：

1. 取 `segment.start/end`
2. 遍历 speaker timeline
3. 计算 overlap
4. 选择 overlap 最大的 speaker
5. 形成 raw 多人逐字稿 segment

### 3. clean

规则：

1. 过滤 `< 0.2s` 的超短说话人段
2. 合并相邻同 speaker 且 gap `<= 0.8s` 的段

### 4. markdown

输出统一格式：

```md
# 多人逐字稿

**[00:03.47 - 00:09.58] SPEAKER_01**  
那个你那个我看你在群里发了
```

### 5. summary

Gemma 输入改为 clean 多人逐字稿文本，保留 speaker 与时间信息。

## 当前工程约束

1. 交接文档中的 Hugging Face token 不落库
2. diarization runner 优先走当前机器的 Python 环境
3. 结果页先做最小改造，只增加多人逐字稿展示
4. `word-level merge` 本轮只预留接口，不完整实现
