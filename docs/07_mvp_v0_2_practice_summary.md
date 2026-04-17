# MeetingSummaryApp MVP v0.2 实践总结

## 版本目标

MVP v0.2 的目标是在 v0.1 已可完成“录音 -> 转写 -> 纪要”的基础上，补上多人逐字稿这一层，让会议纪要建立在更结构化的数据之上。

这个版本的核心不是做 UI 大升级，而是把原有普通 transcript 主链改造成：

1. Whisper 负责“说了什么”
2. pyannote 负责“谁在什么时候说”
3. merge / clean 负责“形成可读的多人逐字稿”
4. Gemma 基于 clean 多人逐字稿生成会议纪要

## 本版本新增能力

当前 v0.2 已新增以下产物：

1. `transcript_raw.json`
2. `speaker_diarization_raw.json`
3. `multi_speaker_transcript_raw.json`
4. `multi_speaker_transcript.json`
5. `multi_speaker_transcript.md`
6. `meeting_minutes.md`

结果页现在展示：

1. 多人逐字稿
2. 会议纪要

## 本版本的关键技术变化

### 1. 引入 pyannote speaker diarization

使用：

- `pyannote/speaker-diarization-community-1`

本机已验证可运行。  
在真实 session 上，pyannote 已能输出 speaker timeline，并写入 `speaker_diarization_raw.json`。

### 2. 增加 segment-level overlap merge

V0.2 没有直接上 word-level merge，而是先实现了更稳的：

- `segment overlap max`

这是正确的工程取舍。  
它不追求极致精度，但足够支撑第一版产品。

### 3. 增加 transcript clean 规则

已加入：

1. 过滤 `< 0.2s` 的超短 speaker 段
2. 合并同 speaker 且 gap `<= 0.8s` 的相邻段

并且修正了一个关键设计错误：

- `raw` 结果必须基于原始 diarization timeline
- `clean` 结果必须基于清洗后的 diarization timeline

这样 raw / clean 才真正可回溯。

### 4. Gemma 输入改为多人逐字稿

会议纪要层不再直接吃普通 transcript，而是改为消费 clean 多人逐字稿文本。

这让纪要生成对说话人关系、任务归属和上下文判断更稳。

## 本版本里做对的事情

### 1. 没有为了赶进度把多人逐字稿和会议纪要混成一层

这个分层是对的：

1. 多人逐字稿是数据层
2. 会议纪要是总结层

这对调试、后续升级和质量分析都非常关键。

### 2. 及时把运行期问题收敛到日志与产物

v0.2 延续了 v0.1 的经验，没有一出问题就猜，而是继续依赖：

1. `session.log`
2. 每个阶段的中间文件

这让很多问题都能精确落到：

1. Whisper 输出异常
2. diarization 结果异常
3. merge 规则异常
4. Gemma 纪要归因异常

### 3. 没有一上来就做 word-level merge

这是对的。  
目前 segment-level merge 已经能跑通，并能支撑真实结果产出。  
如果一开始就冲 word-level，复杂度会显著上升，而且会把调试难度放大很多。

## 本版本踩到的主要坑

### 1. raw / clean 语义容易混

一开始出现过：

- `multi_speaker_transcript_raw.json` 实际已经使用了 clean 后的 diarization timeline

这会直接破坏调试含义。  
这个问题后面已经修正。

### 2. diarization 环境依赖不能想当然

pyannote 依赖比 Whisper 和 Gemma 更脆弱。  
如果没有本地缓存或 Hugging Face token，运行时会直接失败。

因此 v0.2 已补了前置检查：

1. 检查 token
2. 检查本地模型缓存

否则尽早报明确错误。

### 3. 匿名 speaker 不等于真实负责人

多人逐字稿里出现的 `SPEAKER_00 / SPEAKER_01` 只是匿名标签，不是人名。  
如果直接让纪要把它们写进负责人列，会误导读者。

因此本版本补充了任务负责人推断规则，但这仍然只是启发式，不是真实名字映射。

## 当前启发式任务归属规则

v0.2 已经把一些任务归属规则写进纪要生成 prompt：

### 双人会议

如果只有两个 speaker，且任务没有明确点名负责人：

1. 若语境显示是一方向另一方布置任务，默认负责人写“非发言的另一方”
2. 若没有明确线索，但明显是任务布置场景，也默认归给发起任务者的另一方

### 多人会议

如果 speaker 超过 2 人，且任务布置后：

1. 在紧接着 2 秒内
2. 第一个回应“好的”或“收到”的人可识别

则默认该人是任务负责人。

这套规则属于 MVP 级启发式，不是最终的任务归因系统。

## 当前版本边界

v0.2 现在已经是可运行的多人逐字稿版本，但仍然有明确边界：

1. speaker 仍是匿名标签，没有真实姓名映射
2. 仍未实现 word-level merge
3. overlapping speech 还没做显式标记
4. 任务负责人规则仍是启发式，不是严格语义解析
5. 系统音频与麦克风混音仍可能影响 speaker diarization 的质量

## 对下一阶段的建议

下一阶段最值得做的，不是继续堆 prompt，而是提高 speaker 层质量：

1. 评估是否为 diarization 单独准备更偏人声的输入音频
2. 增加 `UNKNOWN` 与不确定归属的可解释输出
3. 做 `word-level merge` 预研
4. 引入 speaker rename / alias 机制
5. 增加“任务归属置信度”或“待人工确认”标记

## 当前结论

MVP v0.2 已经完成了从“普通 transcript 工具”向“多人逐字稿 + 会议纪要工具”的升级。

从工程角度看，这一版最大的价值是：

1. 数据层已经分出来了
2. 中间产物可以回溯
3. 说话人维度开始进入会议纪要主链

这为下一步做更准确的任务归属、多人识别和说话人命名打下了基础。
