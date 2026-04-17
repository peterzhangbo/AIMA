#!/usr/bin/env python3
"""
diarize.py <audio_path>

调用 pyannote.audio 3.x 说话人分离，结果以 JSON 输出到 stdout：
[{"start": 0.123, "end": 2.456, "speaker": "SPEAKER_00"}, ...]

模型已在本地缓存时无需 HF_TOKEN，直接离线加载。
仅在缓存缺失且需要下载时才需要 token。
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
        # 优先从本地缓存加载（不联网）；token 仅在缓存缺失需要下载时有用
        hf_token = read_hf_token()
        try:
            pipeline = Pipeline.from_pretrained(
                "pyannote/speaker-diarization-3.1",
                use_auth_token=hf_token,
            )
        except Exception as e:
            # 如果加载失败且没有 token，给出有用提示
            if hf_token is None:
                print(
                    f"模型加载失败（本地缓存可能不完整）: {e}\n"
                    "如需重新下载，请设置 HF_TOKEN：\n"
                    "  echo 'hf_xxx' > ~/.hf_token",
                    file=sys.stderr,
                )
            else:
                print(f"模型加载失败: {e}", file=sys.stderr)
            sys.exit(4)

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
