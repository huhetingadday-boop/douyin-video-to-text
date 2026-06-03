# douyin-video-to-text

Agent skill that turns a Douyin video URL into readable Chinese text. No browser, no cookie, no login. Works with Claude Code, Codex / OMX, or plain CLI.

## What you get

For each URL, a file lands at `~/Downloads/douyin-transcripts/<aweme_id>.txt`:

```
## desc/hashtags
<caption + #tags from Douyin's API, verbatim>

## transcript
<whisper-transcribed narration, punctuated into paragraphs>
```

Plus a boxed summary on stdout showing per-step timing per URL.

## Requirements

- macOS 12+ (Apple Silicon recommended). Linux likely works with manual `apt install ffmpeg whisper-cpp python3 uv` — untested.
- Homebrew. Install once: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
- ~200 MB free disk (base model) or 1.5 GB (turbo).

Everything else (`uv`, `ffmpeg`, `whisper-cpp`, the whisper model) is auto-installed by `scripts/preflight.sh` via Homebrew. Inside China, preflight auto-detects the network and uses Aliyun (brew + PyPI) + `hf-mirror.com` (HuggingFace) so nothing needs a VPN.

## Usage

Three ways to trigger the same flow:

```bash
# Claude Code
/douyin-video-to-text https://www.douyin.com/video/7621475746078359801

# Codex / OMX
$douyin-video-to-text https://www.douyin.com/video/7621475746078359801

# Plain CLI (no agent)
bash scripts/preflight.sh
bash scripts/run.sh https://www.douyin.com/video/7621475746078359801
```

Also triggers on natural-language asks: "抖音视频转文字", "extract 文案", "transcribe this douyin url".

Accepted URL forms:
- `https://www.douyin.com/video/<id>`
- `https://www.douyin.com/user/.../?modal_id=<id>`
- `https://v.douyin.com/<short>/` (auto-resolved)

## How it works

```
URL → curl ttwid endpoint → uvx f2 dy → ffmpeg → whisper-cli → srt_to_readable.py → .txt
```

Douyin's web API requires a JS-computed `X-Bogus`/`msToken`/`a_bogus` signature header. The `f2` Python package generates these locally, so we only need an anonymous `ttwid` cookie — fetched ourselves with one `curl` POST to Douyin's public registration endpoint each run. The user never touches a cookie.

## Install

`scripts/preflight.sh` is idempotent. On first run it installs `uv`, `ffmpeg`, `whisper-cpp`, and the 141 MB whisper base model in parallel. On subsequent runs it exits in <3 s with a status banner.

Inside China the script auto-detects and switches to Aliyun + Tsinghua + hf-mirror.com mirrors. If the install still stalls (`V2T_BREW_TIMEOUT`, default 90 s) the script kills brew and prompts the user via a TTY menu or native macOS dialog to pick a different mirror.

## Optional: better quality model

The base whisper model (141 MB) outputs Traditional Chinese with occasional errors. For better Mandarin quality, fetch turbo once:

```bash
# Outside China
curl -L -o ~/.local/share/whisper-models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin

# Inside China
curl -L -o ~/.local/share/whisper-models/ggml-large-v3-turbo.bin \
  https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

`run.sh` auto-picks turbo when present. Apple Silicon transcribes a 4-min video in ~3 seconds.

## Environment variables

| Var | Effect |
|---|---|
| `V2T_DEBUG=1` | Stream f2 / whisper-cli output live (also disables the TTY spinner) |
| `V2T_KEEP=1` | Keep the temp work dir after a successful run (debug) |
| `V2T_NO_SPINNER=1` | Disable the TTY spinner on interactive terminals |
| `V2T_NO_COLOR=1` | Disable ANSI color in summary banners |
| `V2T_CN_MIRROR=auto\|aliyun\|tuna\|ustc\|default` | Force mirror selection (default `auto`) |
| `V2T_BREW_TIMEOUT=<sec>` | Stall threshold before brew is killed and mirror prompt shown (default 90) |
| `DOUYIN_TRANSCRIPT_DIR=/path` | Output directory (default `~/Downloads/douyin-transcripts`) |
| `WHISPER_MODEL_DIR=/path` | Model search dir (default `~/.local/share/whisper-models`) |

On failure, the work dir is always kept and the script prints its path plus an `env.txt` snapshot. Attach those when filing issues.

## Troubleshooting

See `references/failure-modes.md` for the full per-category playbook. Quick reference:

| Failure category | Likely cause | What to do |
|---|---|---|
| `parse` | URL form not recognized | Paste the canonical `/video/<id>` form |
| `douyin-network` | Douyin/ByteDance unreachable | Check network/VPN; retry |
| `f2-download` | Video deleted, region-locked, or login-required | Skip — not retrievable without a logged-in cookie |
| `ffmpeg` | Audio extraction failed | Inspect `<work>/ffmpeg.log` |
| `whisper` | Model file missing or corrupted | `rm -rf ~/.local/share/whisper-models && bash scripts/preflight.sh` |
| `srt-format` | Empty transcript | Check `<work>/transcript.srt` — video may be music-only |

## Privacy & responsible use

- The ttwid cookie is fetched fresh each run and discarded — never persisted, never tied to any account.
- Personal research / accessibility / note-taking on videos you have legitimate access to. Don't redistribute downloaded content. Don't mass-scrape Douyin.
- The downloaded mp4 is removed after transcription; only the text remains.

## Smoke test

```bash
git clone https://github.com/huhetingadday-boop/douyin-video-to-text.git /tmp/dv2t
bash /tmp/dv2t/scripts/preflight.sh
bash /tmp/dv2t/scripts/run.sh https://www.douyin.com/video/7621475746078359801
```

Or use the regression harness:

```bash
bash tests/douyin-video-to-text/run.sh
```

## Why not yt-dlp / Chrome cookies / Chrome MCP

Earlier versions tried those paths. They all failed:
- yt-dlp with `--cookies-from-browser chrome` → macOS Keychain password prompts that block the terminal
- yt-dlp with `--cookies-from-browser safari` → Full Disk Access errors
- Copying Chrome's cookie SQLite → file is locked while Chrome runs
- Raw `curl` to the internal API → 200 OK with empty body (lacks JS-signed headers)
- Claude-in-Chrome MCP → works but requires installing a Chrome extension and keeping a logged-in tab open

The `uvx f2` path sidesteps all of this.

## Credits

- [f2](https://github.com/Johnserf-Seed/f2) — Douyin signing (`X-Bogus` / `a_bogus` / `msToken`).
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — local Whisper inference.
