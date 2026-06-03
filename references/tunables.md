# Tunables

## Whisper model quality

Default is `ggml-base.bin` (141 MB, ~3 s per 4 min audio, Traditional Chinese + occasional errors). Upgrade once for better Mandarin quality:

```bash
curl -L -o ~/.local/share/whisper-models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

When inside China, swap the host for the mirror:

```bash
curl -L -o ~/.local/share/whisper-models/ggml-large-v3-turbo.bin \
  https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

`run.sh` auto-picks turbo when it exists. On Apple Silicon, turbo transcribes a 4-min video in ~3 seconds.

## Output directory

Always `~/Downloads/douyin-transcripts/<aweme_id>.txt` unless you override via `DOUYIN_TRANSCRIPT_DIR`.

## Whisper model directory

Default `~/.local/share/whisper-models/`. Override via `WHISPER_MODEL_DIR`.

## China mirror

`preflight.sh` auto-detects via a quick probe of `https://www.google.com`. When unreachable it switches to Aliyun for brew + PyPI and `hf-mirror.com` for HuggingFace. Force the mirror with `V2T_CN_MIRROR=aliyun|tuna|ustc|default`. Disable mirroring with `V2T_CN_MIRROR=default`.

## Brew install stall timeout

`V2T_BREW_TIMEOUT=<seconds>` (default 90). If brew's log stops growing for this long, preflight kills the install and prompts the user to pick a different mirror.

## Debug verbosity

- `V2T_DEBUG=1` — stream `f2` + `whisper-cli` output live (also disables the spinner so output isn't garbled).
- `V2T_KEEP=1` — keep the temp work dir after success (mp4, srt, f2.log, whisper.log, env.txt).
- `V2T_NO_SPINNER=1` — disable the TTY spinner even when the terminal supports it.
- `V2T_NO_COLOR=1` — disable ANSI color in summary banners.
