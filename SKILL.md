---
name: douyin-video-to-text
description: Turn a Douyin video URL into readable Chinese text (transcript + caption/hashtags) on macOS. Zero user setup — no browser, no cookie, no login. Triggers on Douyin URLs and asks like "抖音转文字", "transcribe douyin", "extract 文案". Works in Claude Code, Codex, OMX, and plain CLI.
compatibility: Requires macOS 12+ and Homebrew. Auto-installs uv, ffmpeg, whisper-cpp, and the whisper base model on first run. ~200 MB disk (base model) or 1.5 GB (turbo).
---

# douyin-video-to-text

Given one or more Douyin URLs, produce a readable `<aweme_id>.txt` per video in `~/Downloads/douyin-transcripts/`. Pure CLI pipeline — no browser, no logged-in cookie, no Chrome extension, no MCP.

## Trigger

The user provides one or more Douyin URLs and asks to extract 文案 / transcript / video-to-text / 转文字. Accepted URL forms:
- `https://www.douyin.com/video/<id>`
- `https://www.douyin.com/user/<...>?modal_id=<id>&...`
- short link `https://v.douyin.com/xxx/` (resolved automatically)

## How it works

1. `curl` POST to Douyin's public ttwid registration endpoint → returns an anonymous `ttwid` cookie valid for one year. No user authentication.
2. `uvx --from f2 f2 dy` → downloads no-watermark mp4 + caption/hashtags using that ttwid. `f2` generates `X-Bogus` / `msToken` / `a_bogus` locally in Python.
3. `ffmpeg` → 16 kHz mono WAV.
4. `whisper-cli` (whisper.cpp) → SRT.
5. `srt_to_readable.py` → punctuated paragraphs.

The ttwid is fetched fresh each run and discarded — never persisted, never tied to any account.

## Steps

### Step 1 — Preflight (idempotent; fast when nothing is missing)

```bash
bash "$SKILL_DIR/scripts/preflight.sh"
```

What it does:
- Verifies macOS + Homebrew.
- Auto-detects China network and applies Aliyun (brew + PyPI) + hf-mirror.com (HuggingFace) when needed.
- Parallel `brew install` + HuggingFace model download — first run takes ~30-60 s with cached bottles, longer on a clean Mac.
- If brew stalls past 90 s, prompts the user (TTY menu or native macOS dialog) to pick a different mirror and retries.
- Subsequent runs exit in <3 s and print a boxed status banner.

### Step 2 — Process URLs

```bash
bash "$SKILL_DIR/scripts/run.sh" "<url1>" ["<url2>" ...]
```

Per URL the script prints step-by-step progress with timing. The lines have a stable shape so agents and tests can parse them:

```
[v2t 1/2 ?] resolving URL → aweme_id ...
[v2t 1/2 7621...] resolve done in 0s
[v2t 1/2 7621...] fetching anonymous ttwid cookie ...
[v2t 1/2 7621...] ttwid done in 1s
[v2t 1/2 7621...] downloading mp4 + caption via f2==0.0.1.7 ...
[v2t 1/2 7621...] download done in 4s
[v2t 1/2 7621...] extracting 16 kHz mono audio with ffmpeg ...
[v2t 1/2 7621...] audio done in 0s
[v2t 1/2 7621...] transcribing with ggml-base.bin ...
[v2t 1/2 7621...] transcribe done in 12s
[v2t 1/2 7621...] punctuating + paragraphing SRT ...
[v2t 1/2 7621...] format done in 0s
[v2t 1/2 7621...] DONE → /Users/<you>/Downloads/douyin-transcripts/<aweme_id>.txt
----- <aweme_id> -----
## desc/hashtags
<caption + tags from Douyin>

## transcript
<readable Chinese paragraphs>
----------
```

A boxed summary lands at the end showing per-URL per-step timing. On TTY, long steps display a live spinner with elapsed seconds; the agent-visible step lines still get printed verbatim.

### Step 3 — Present to user

Show the `## desc/hashtags` and `## transcript` blocks for each video, plus the file path. Don't re-read the file — `run.sh` already prints it. For batch mode, the summary box at the end already covers counts and timing.

## Locating `$SKILL_DIR`

`$SKILL_DIR` is just where this skill is checked out. The scripts self-locate, so absolute paths also work:

- Claude Code: `~/.claude/skills/douyin-video-to-text/` (may be a symlink to a dev checkout)
- Codex / OMX: `~/.codex/skills/douyin-video-to-text/` or the project's `skills/` dir
- Plain CLI: wherever you cloned the repo

If unsure: `realpath "$(dirname "$(find ~/.claude ~/.codex ~/.config -name 'SKILL.md' -path '*douyin-video-to-text*' 2>/dev/null | head -1)")"`.

## Env vars

- `V2T_DEBUG=1` — stream f2 and whisper output live (also disables the spinner).
- `V2T_KEEP=1` — keep the temp work dir after success (debug only).
- `V2T_NO_SPINNER=1` — disable the TTY spinner even on interactive terminals.
- `V2T_CN_MIRROR=auto|aliyun|tuna|ustc|default` — control mirror selection (default `auto`).
- `V2T_BREW_TIMEOUT=<sec>` — stall threshold before brew is killed and a mirror prompt is shown (default 90).
- `V2T_WHISPER_PROCESSORS=N` — whisper `-p` (parallel processors splitting audio). Default auto from `hw.perflevel0.physicalcpu` (Apple Silicon) or `hw.physicalcpu` (Intel), capped at 4. Each slot holds its own model state (~1.5 GB for large-v3-turbo).
- `V2T_WHISPER_THREADS=M` — whisper `-t` (threads per processor). Default auto so that `N*M ≈ perf cores`, capped at 4.
- `DOUYIN_TRANSCRIPT_DIR=/path` — output directory (default `~/Downloads/douyin-transcripts`).
- `WHISPER_MODEL_DIR=/path` — model search dir (default `~/.local/share/whisper-models`).

## Failure modes

`run.sh` tags every failure with `category=<cat>`. See `references/failure-modes.md` for the per-category playbook and the list of forbidden fallbacks (yt-dlp Chrome cookies, third-party scrapers, etc.).

Quick reference:
- `parse` → ask user to paste a canonical `/video/<id>` URL.
- `douyin-network` → check network/VPN, retry once.
- `f2-download` → video is deleted, region-locked, or login-required. Skip and continue.
- `ffmpeg` → audio extraction error. Inspect `<work>/ffmpeg.log`.
- `whisper` → model missing or corrupted. `rm -rf ~/.local/share/whisper-models && bash preflight.sh`.
- `srt-format` → empty transcript. Often music-only or silent video.

On any failure the work dir is kept and the script prints its path plus an `env.txt` snapshot. Attach those when filing issues.

## Batch mode

```bash
bash "$SKILL_DIR/scripts/run.sh" \
  "https://www.douyin.com/video/A" \
  "https://www.douyin.com/video/B" \
  "https://www.douyin.com/video/C"
```

Each URL is processed independently. One bad URL (deleted video, parse error) does not stop the rest — the script exits non-zero only after attempting all of them.

## Tunables and internals

See `references/tunables.md` for model upgrade instructions, China mirror flags, and other configuration knobs. See `references/failure-modes.md` for the failure-category playbook and notes on `f2` internals.
