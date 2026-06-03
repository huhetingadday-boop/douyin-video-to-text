# Failure modes

`run.sh` tags every failure with a category. Lines look like:

```
[v2t FAIL] category=<cat>  aweme_id=<id>  <message>
```

Reactions per category:

- `category=douyin-network` — Douyin/ByteDance unreachable (ttwid bootstrap failed after retries). Ask the user to check network/VPN. Do NOT improvise (no yt-dlp, no Chrome cookies, no Safari). Retry once after they confirm.
- `category=parse` — URL form not recognized. Ask the user to paste the URL in the form `https://www.douyin.com/video/<id>`. Do not try to scrape unknown URL shapes.
- `category=f2-download` — video was likely deleted, region-locked, or login-required. Report the aweme_id as skipped and continue with the rest. Do not retry with cookies — for login-only videos the answer is "skip".
- `category=ffmpeg` — audio extraction failed. The script tails the ffmpeg log automatically; relay it to the user.
- `category=whisper` — usually missing model or corrupted file. Suggest `rm -rf ~/.local/share/whisper-models && bash scripts/preflight.sh`.
- `category=srt-format` — empty transcript (music-only / silent video). Report and continue.

On any failure the work dir is kept and a debug bundle path is printed (`env.txt` + per-step `*.log`). Ask the user to attach those when filing issues.

# Forbidden fallbacks

These were tried in earlier versions and produced bad UX — never go down these paths:

- `yt-dlp --cookies-from-browser chrome|safari` → triggers macOS Keychain password prompts (modal blocks the terminal) or Full Disk Access errors. Do not use.
- Copying Chrome's `Cookies` SQLite from `Application Support/Google/Chrome/Default/` → locked while Chrome runs; fragile across Chrome versions.
- Direct `curl` to `aweme/v1/web/aweme/detail/` without f2 → returns HTTP 200 with empty body because it lacks the JS-computed `a_bogus`/`msToken` signature. f2 is the layer that handles this.
- Third-party download sites (snaptik.app, douyin.iiilab.com) requiring user interaction → out of scope for an automated agent path.

# Internals

- `f2`'s download URL points to Douyin's `download_addr` (no watermark, not `play_addr` which carries a watermark).
- Caption + hashtags from Douyin's metadata are kept verbatim in the output — they're frequently the "real" 文案 (especially for AI-art / music-only videos with no narration).
- Temp files live in `$(mktemp -d -t dy-v2t.XXXXXX)` and are deleted on script exit (incl. on error via trap).
- whisper flags `--max-len 50 --entropy-thold 2.4 --no-fallback` prevent hallucination loops on silent or near-silent segments.
