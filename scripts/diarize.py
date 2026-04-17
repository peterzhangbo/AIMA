#!/usr/bin/env python3
"""
diarize.py <audio_path>

调用本地缓存的 pyannote 说话人分离模型，结果以 JSON 输出到 stdout：
[{"start": 0.123, "end": 2.456, "speaker": "SPEAKER_00"}, ...]

纯本地运行，不联网。模型从 ~/.cache/huggingface/hub/ 加载。
"""

import os
# 必须在所有 huggingface/pyannote import 之前设置，禁止任何网络请求
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"

import sys
import json

MODEL_ID = "pyannote/speaker-diarization-community-1"

def main():
    if len(sys.argv) < 2:
        print("Usage: diarize.py <audio_path>", file=sys.stderr)
        sys.exit(1)

    audio_path = sys.argv[1]
    if not os.path.isfile(audio_path):
        print(f"File not found: {audio_path}", file=sys.stderr)
        sys.exit(1)

    try:
        from pyannote.audio import Pipeline
    except ImportError:
        print(
            "pyannote.audio 未安装。请运行：\n"
            "  pip install pyannote.audio",
            file=sys.stderr,
        )
        sys.exit(3)

    try:
        pipeline = Pipeline.from_pretrained(MODEL_ID)
    except Exception as e:
        print(f"模型加载失败: {e}", file=sys.stderr)
        sys.exit(4)

    # Apple Silicon：优先使用 MPS
    try:
        import torch
        if torch.backends.mps.is_available():
            pipeline.to(torch.device("mps"))
    except Exception:
        pass

    try:
        result = pipeline(audio_path)
        # pyannote 4.x 返回 DiarizeOutput；itertracks 在 .speaker_diarization 上
        annotation = getattr(result, "speaker_diarization", result)
        segments = [
            {
                "start": round(turn.start, 3),
                "end": round(turn.end, 3),
                "speaker": speaker,
            }
            for turn, _, speaker in annotation.itertracks(yield_label=True)
        ]
        print(json.dumps(segments, ensure_ascii=False))
    except Exception as e:
        print(f"Diarization 失败: {e}", file=sys.stderr)
        sys.exit(4)

if __name__ == "__main__":
    main()
