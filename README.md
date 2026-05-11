# AIMA — AI Meeting Assistant

**AIMA** 是一款 macOS 原生会议助手，全程本地运行，不联网、不上传数据。

录制麦克风 + 系统音频 → Whisper 转写 → pyannote 说话人分离 → Gemma 生成结构化会议纪要。

---

## 系统要求

| 项目 | 要求 |
|------|------|
| 芯片 | Apple Silicon（M1 / M2 / M3 / M4） |
| 系统 | macOS 14 Sonoma 及以上 |
| 内存 | 建议 ≥ 16GB，最低 8GB（自动降档） |
| 磁盘 | 模型缓存约 3–22GB（按档位） |

> Intel Mac 暂不支持（依赖 MLX 框架）。

---

## 功能特性

- 🎙️ **双轨录音**：同时录制麦克风（自己的声音）与系统音频（对端声音）
- 📝 **本地转写**：`mlx_whisper`（Whisper large-v3-turbo），支持中英文
- 👥 **说话人分离**：`pyannote.audio`，可选装，生成多人逐字稿
- 🤖 **AI 摘要**：`mlx_vlm`（Gemma 4 系列），按内存档位自动选模型
- 📋 **结构化纪要**：标题、概述、总结、决策、讨论要点、待办、风险 7 个章节
- ⏸️ **暂停/恢复**：录制中途可暂停，不影响最终纪要质量
- 🔄 **并发队列**：录制完毕立即可开始下一场，处理在后台排队进行
- 📁 **历史管理**：所有会议本地持久化，支持重新生成纪要

---

## 模型档位（按内存自动选择）

| 内存 | Whisper | Gemma |
|------|---------|-------|
| ≥ 32GB | large-v3-turbo | gemma-4-31b-it-4bit |
| 16–32GB | large-v3-turbo | gemma-4-26b-a4b-it-4bit |
| 12–16GB | large-v3-turbo | gemma-4-e4b-it-4bit |
| 8–12GB | large-v3-turbo | gemma-4-e2b-it-4bit |

---

## 安装（普通用户）

1. 前往 [Releases](https://github.com/peterzhangbo/AIMA/releases) 下载最新 `AIMA-x.x.x.zip`
2. 解压，将 `AIMA.app` 拖入 `/Applications`
3. 右键 → 打开（首次需通过 Gatekeeper）
4. 按权限页引导安装依赖工具和模型

---

## 依赖工具（权限页自动引导安装）

```bash
# Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Python 3 + pip 工具
brew install python3 ffmpeg

# HuggingFace CLI（用于下载模型）
brew install pipx && pipx install huggingface_hub[cli]

# MLX 推理库
pip3 install mlx-whisper mlx-vlm

# 说话人分离（可选）
pip3 install pyannote.audio
hf auth login
hf download pyannote/speaker-diarization-community-1
```

> 中国大陆用户可在模型下载命令前加 `HF_ENDPOINT=https://hf-mirror.com`

---

## 开发者构建

### 环境

- Xcode Command Line Tools：`xcode-select --install`
- Swift 5.9+

### 本地调试

```bash
git clone https://github.com/peterzhangbo/AIMA.git
cd AIMA
swift build
bash scripts/build_app.sh debug
open .build/debug/AIMA.app
```

### Release 构建（ad-hoc 签名，本机运行）

```bash
bash scripts/build_app.sh release
open .build/release/AIMA.app
```

### Release 构建（Developer ID 签名 + 公证，可分发）

```bash
VERSION=x.x.x \
SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=YOUR_NOTARY_PROFILE \
bash scripts/build_release.sh
```

公证前置配置：
```bash
xcrun notarytool store-credentials "YOUR_NOTARY_PROFILE" \
  --apple-id <Apple ID> \
  --team-id <Team ID> \
  --password <App-Specific Password>
```

---

## 项目结构

```
Sources/SummaryMeetingApp/
├── App/                    # 应用入口、AppDelegate、全局状态
├── Features/
│   ├── Permissions/        # 权限与依赖检测页
│   ├── Recording/          # 录制页
│   ├── History/            # 历史会议列表
│   └── Detail/             # 会议详情 / 纪要展示
├── Services/
│   ├── Capture/            # MicRecorder、SystemAudioRecorder、AudioMixer
│   ├── AI/                 # WhisperRunner、GemmaRunner、DiarizeRunner
│   ├── RecordingCoordinator.swift
│   ├── MeetingStore.swift  # GRDB SQLite 持久化
│   └── TaskQueue.swift     # 处理任务队列（崩溃恢复）
└── Shared/                 # 模型定义、SessionPaths 等
scripts/
├── build_app.sh            # 本地 .app 打包
├── build_release.sh        # 签名 + 公证 + zip 分发包
└── diarize.py              # pyannote 说话人分离脚本
```

---

## License

MIT
