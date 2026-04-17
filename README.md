# SummaryMeeting

macOS 原生会议纪要工具。录制系统音频+麦克风，本地 Whisper 转写、pyannote 说话人分离、Gemma 生成纪要。

设计文档见 [`docs/`](docs/)，实施计划见 `~/.claude/plans/generic-whistling-pancake.md`。

## 运行（开发态）

```bash
swift run SummaryMeetingApp
```

## 打包为 .app（获取麦克风/屏幕录制权限）

```bash
bash scripts/build_app.sh debug
open .build/debug/SummaryMeetingApp.app
```

## 环境依赖（本机）

- `/usr/local/bin/python3`
- `mlx_whisper`、`mlx_vlm`
- `ffmpeg`
- pyannote 模型缓存 + `HF_TOKEN`

详见 `docs/01_environment_baseline.md`。
