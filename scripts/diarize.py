#!/usr/bin/env python3
"""
diarize.py <audio_path>

调用 pyannote.audio 3.x 说话人分离，结果以 JSON 输出到 stdout：
[{"start": 0.123, "end": 2.456, "speaker": "SPEAKER_00"}, ...]

环境要求：
  pip install pyannote.audio
  export HF_TOKEN=<huggingface_token>   (或 ~/.hf_token / ~/.huggingface/token)
"""

import sys
import json
import os

def read_hf_token() -> str | None:
    token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")
    if token:
        return token.strip()
    for p in [
        os.path.expanduser("~/.hf_token"),
        os.path.expanduser("~/.huggingface/token"),
    ]:
        if os.path.isfile(p):
            t = open(p).read().strip()
            if t:
                return t
    return None

def main():
    if len(sys.argv) < 2:
        print("Usage: diarize.py <audio_path>", file=sys.stderr)
        sys.exit(1)

    audio_path = sys.argv[1]
    if not os.path.isfile(audio_path):
        print(f"File not found: {audio_path}", file=sys.stderr)
        sys.exit(1)

    hf_token = read_hf_token()
    if not hf_token:
        print(
            "HF_TOKEN 未设置。请在 ~/.hf_token 中写入 Hugging Face token，"
            "或通过环境变量 HF_TOKEN= 传入。",
            file=sys.stderr,
        )
        sys.exit(2)

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
        pipeline = Pipeline.from_pretrained(
            "pyannote/speaker-diarization-3.1",
            use_auth_token=hf_token,
        )

        # Apple Silicon：优先使用 MPS
        try:
            import torch
            if torch.backends.mps.is_available():
                pipeline.to(torch.device("mps"))
        except Exception:
            pass

        diarization = pipeline(audio_path)

        segments = []
        for turn, _, speaker in diarization.itertracks(yield_label=True):
            segments.append(
                {
                    "start": round(turn.start, 3),
                    "end": round(turn.end, 3),
                    "speaker": speaker,
                }
            )

        print(json.dumps(segments, ensure_ascii=False))

    except Exception as e:
        print(f"Diarization 失败: {e}", file=sys.stderr)
        sys.exit(4)

if __name__ == "__main__":
    main()
