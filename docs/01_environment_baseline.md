# 会议纪要产品 MVP 环境基线

## 目的

本文档用于固化当前已经确认可用的本地环境口径。后续开发默认以本文档为准，不再重复讨论模型与命令行基础环境。

---

## 系统与解释器

- 当前项目目录：`/Users/saul/Documents/Develop/meetingSummary`
- 当前可用 Python：`/usr/local/bin/python3`
- 后续统一使用：`python3`
- 不依赖 `python`

---

## Whisper 环境基线

### 固定命令

```bash
mlx_whisper "<audio_path>" \
  --model mlx-community/whisper-large-v3-turbo \
  --language zh \
  --word-timestamps True \
  --temperature 0 \
  --condition-on-previous-text True \
  --hallucination-silence-threshold 0.6 \
  --max-words-per-line 20 \
  --max-line-count 2 \
  -f json \
  -o "<output_dir>"
```

### 说明

- 上述命令为用户历史上已成功调用的实际口径。
- 后续产品实现默认按该配置执行。
- 输出格式固定为 `json`。
- 输入语言固定为中文。
- 解析器优先适配 `segments`，其次适配 `words`。
- 经当前机器上的真实 CLI 验证，代码层实际调用时必须使用连字符参数名，而不是下划线参数名。

### 已确认事实

- `mlx-whisper` 已安装。
- Whisper 模型 `mlx-community/whisper-large-v3-turbo` 已存在本地缓存。
- 当前 Codex 会话内未直接解析到 `mlx_whisper` 的 PATH 能力，但用户已明确确认其在真实终端环境中可正常运行。
- 因此开发时应将该命令视为标准可用命令，而不是继续纠结环境探测。

---

## Gemma 环境基线

### 固定命令

```bash
python3 -m mlx_vlm generate \
  --model mlx-community/gemma-4-26b-a4b-it-4bit \
  --max-tokens 50000 \
  --temperature 0.0 \
  --prompt "你的提示词"
```

### 说明

- 当前环境中不使用 `python3 -m mlx_vlm.generate` 作为正式口径。
- 当前环境中也不使用 `mlx_vlm generate` 作为正式口径，因为 shell 中没有该裸命令入口。
- 后续产品代码默认按 `python3 -m mlx_vlm generate` 执行。

### 已确认事实

- `mlx-vlm` 已安装，版本为 `0.4.3`。
- `mlx_vlm` 模块可正常导入。
- `mlx_lm` 模块可正常导入。
- 本地模型缓存已存在：
  `mlx-community/gemma-4-26b-a4b-it-4bit`
- 实测最小中文推理已成功完成。
- 一次实测峰值内存约为 `15.687 GB`。

### 风险说明

- `--max-tokens 50000` 只是生成上限，不代表任意输入都能稳定完整输出。
- 长 transcript 后续需要预留切片摘要与二次汇总方案。

---

## 相关依赖状态

### 已安装

- `transformers`
- `torch`
- `sentencepiece`
- `safetensors`
- `huggingface_hub`
- `ffmpeg`

### 未安装

- `accelerate`

说明：

- 当前 MVP 已确认的摘要路线基于 `mlx_vlm`，因此 `accelerate` 当前不是阻塞项。

---

## 样例输入

- 当前仓库样例音频：
  `/Users/saul/Documents/Develop/meetingSummary/Impromptu.m4a`

该文件后续可用于端到端验证：

- 录音后处理链路
- Whisper 转写链路
- Transcript 解析链路
- Gemma 纪要生成链路

---

## 最终环境结论

后续开发只认这两条标准命令：

```bash
mlx_whisper "<audio_path>" \
  --model mlx-community/whisper-large-v3-turbo \
  --language zh \
  --word-timestamps True \
  --temperature 0 \
  --condition-on-previous-text True \
  --hallucination-silence-threshold 0.6 \
  --max-words-per-line 20 \
  --max-line-count 2 \
  -f json \
  -o "<output_dir>"
```

```bash
python3 -m mlx_vlm generate \
  --model mlx-community/gemma-4-26b-a4b-it-4bit \
  --max-tokens 50000 \
  --temperature 0.0 \
  --prompt "你的提示词"
```
