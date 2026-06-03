#!/usr/bin/env bash
# douyin-video-to-text — turn a Douyin URL into a readable text file.
# Usage: run.sh <url> [<url> ...]
# Output: $DOUYIN_TRANSCRIPT_DIR/<aweme_id>.txt   (default ~/Downloads/douyin-transcripts/)
#
# Zero user setup: bootstraps an anonymous ttwid via Douyin's public
# registration endpoint each run. No browser, no logged-in cookie.
#
# Env vars:
#   V2T_DEBUG=1               stream f2/whisper live (disables TTY spinner)
#   V2T_KEEP=1                keep WORK_DIR after success (debug)
#   V2T_NO_SPINNER=1          force no spinner even on TTY
#   V2T_WHISPER_PROCESSORS=N  whisper -p (parallel processors). Default auto.
#   V2T_WHISPER_THREADS=M     whisper -t (threads per processor). Default auto.
#   DOUYIN_TRANSCRIPT_DIR=... override output directory
#   WHISPER_MODEL_DIR=...     override ~/.local/share/whisper-models
#
# Stable machine-parseable lines (agents and tests rely on these):
#   [v2t N/M ID] <step> ...                — step started
#   [v2t N/M ID] <step> done in <secs>s    — step finished
#   [v2t N/M ID] DONE → <path>             — per-URL success
#   [v2t FAIL] category=<cat> aweme_id=<id> <msg>   — per-URL failure
#   [v2t] Processed K/M videos in <secs>s. ...      — batch summary

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${DOUYIN_TRANSCRIPT_DIR:-${HOME}/Downloads/douyin-transcripts}"
MODEL_DIR="${WHISPER_MODEL_DIR:-${HOME}/.local/share/whisper-models}"
WORK_DIR="$(mktemp -d -t dy-v2t.XXXXXX)"
F2_VERSION="0.0.1.7"

# --- color (subtle; only on TTY) --------------------------------------------

if [ -t 1 ] && [ -z "${V2T_NO_COLOR:-}" ]; then
  C_DIM="\033[2m"; C_BOLD="\033[1m"
  C_CYAN="\033[36m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"; C_RED="\033[31m"
  C_RST="\033[0m"
else
  C_DIM=""; C_BOLD=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RST=""
fi

# --- state ------------------------------------------------------------------

CURRENT_URL_IDX=0
TOTAL_URLS=0
CURRENT_AWEME_ID=""
LAST_STEP=""
LAST_STEP_T0=0
LAST_RC=0
SPIN_PID=""

# Per-URL timing breakdown (parallel arrays — bash 3.2 compat).
# Reset at start of each process_one; flushed into the global RUN_* arrays.
declare -a STEP_NAMES; STEP_NAMES=()
declare -a STEP_SECS;  STEP_SECS=()
declare -a RUN_IDS;    RUN_IDS=()
declare -a RUN_TIMING; RUN_TIMING=()  # encoded "name1=N name2=M" per URL
declare -a RUN_STATUS; RUN_STATUS=()  # "ok" or "fail:<category>"

# --- cleanup ----------------------------------------------------------------

cleanup_workdir() {
  spin_stop
  if [ -n "${V2T_KEEP:-}" ] || [ "$LAST_RC" -ne 0 ]; then
    echo "[v2t] WORK_DIR kept for debug: ${WORK_DIR}" >&2
    if [ "$LAST_RC" -ne 0 ]; then
      cat >&2 <<EOF
[v2t] Debug bundle:
[v2t]   - work dir:  ${WORK_DIR}
[v2t]   - run env:   ${WORK_DIR}/env.txt
[v2t]   - last step: ${LAST_STEP:-<none>}
[v2t] When opening an issue, attach env.txt and the matching <step>.log.
EOF
    fi
  else
    rm -rf "${WORK_DIR}"
  fi
}

write_env_snapshot() {
  {
    echo "# douyin-video-to-text debug snapshot"
    echo "date:      $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "uname:     $(uname -a)"
    echo "sw_vers:"; sw_vers 2>/dev/null | sed 's/^/  /'
    echo "uv:        $(uv --version 2>/dev/null || echo MISSING)"
    echo "python3:   $(python3 --version 2>&1 || echo MISSING)"
    echo "ffmpeg:    $(ffmpeg -version 2>/dev/null | head -1 || echo MISSING)"
    echo "whisper:   $(brew list --versions whisper-cpp 2>/dev/null || echo MISSING)"
    echo "f2 pinned: ${F2_VERSION}"
    echo "model:     ${MODEL:-<unset>}"
    echo "out_dir:   ${OUT_DIR}"
    echo "urls:      $*"
  } >"${WORK_DIR}/env.txt"
}

on_exit() {
  LAST_RC=$?
  cleanup_workdir
  exit "$LAST_RC"
}
trap on_exit EXIT INT TERM

# --- model selection --------------------------------------------------------

MODEL_TURBO="${MODEL_DIR}/ggml-large-v3-turbo.bin"
MODEL_BASE="${MODEL_DIR}/ggml-base.bin"
MODEL=""
[ -f "${MODEL_TURBO}" ] && MODEL="${MODEL_TURBO}"
[ -z "${MODEL}" ] && [ -f "${MODEL_BASE}" ] && MODEL="${MODEL_BASE}"
if [ -z "${MODEL}" ]; then
  echo -e "${C_RED}[v2t] FAIL:${C_RST} no whisper model found in ${MODEL_DIR}." >&2
  echo "[v2t]   Run scripts/preflight.sh to fetch ggml-base.bin." >&2
  exit 1
fi

UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
mkdir -p "${OUT_DIR}"

# --- whisper parallelism autotune ------------------------------------------
# Goal: keep p*t close to the count of performance cores so threads never
# fight over the same physical core. On Apple Silicon, perf cores >> efficiency
# cores for transformer math — count perflevel0 only. Each `-p` slot loads
# its own model state (~1.5 GB for large-v3-turbo); 4 slots = ~6 GB.

PERF_CORES=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null \
             || sysctl -n hw.physicalcpu 2>/dev/null \
             || sysctl -n hw.ncpu 2>/dev/null \
             || echo 4)

clamp() { local v=$1 lo=$2 hi=$3; [ "$v" -lt "$lo" ] && v=$lo; [ "$v" -gt "$hi" ] && v=$hi; echo "$v"; }

WHISPER_P="${V2T_WHISPER_PROCESSORS:-}"
WHISPER_T="${V2T_WHISPER_THREADS:-}"
if [ -z "$WHISPER_P" ]; then WHISPER_P=$(clamp $((PERF_CORES / 2)) 1 4); fi
if [ -z "$WHISPER_T" ]; then WHISPER_T=$(clamp $((PERF_CORES / WHISPER_P)) 1 4); fi

# --- spinner (TTY-only stderr overlay) --------------------------------------

spin_start() {
  local msg="$1"
  if [ ! -t 2 ] || [ -n "${V2T_DEBUG:-}" ] || [ -n "${V2T_NO_SPINNER:-}" ]; then
    return
  fi
  (
    local frames="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local i=0 t0
    t0=$(date +%s)
    while :; do
      local c="${frames:$((i % 10)):1}"
      printf "\r\033[2K  ${C_CYAN}%s${C_RST} %s ${C_DIM}(%ds)${C_RST}" "$c" "$msg" $(( $(date +%s) - t0 )) >&2
      i=$((i + 1))
      sleep 0.1
    done
  ) &
  SPIN_PID=$!
  disown "$SPIN_PID" 2>/dev/null || true
}

spin_stop() {
  [ -n "$SPIN_PID" ] || return 0
  kill "$SPIN_PID" 2>/dev/null
  wait "$SPIN_PID" 2>/dev/null || true
  SPIN_PID=""
  [ -t 2 ] && printf "\r\033[2K" >&2 || true
}

# --- progress logging -------------------------------------------------------

now_s() { date +%s; }

prog() {
  # prog <step-name> <human message>
  local now elapsed
  now=$(now_s)
  if [ -n "$LAST_STEP" ]; then
    elapsed=$((now - LAST_STEP_T0))
    spin_stop
    printf "[v2t %d/%d %s] %s done in %ss\n" \
      "$CURRENT_URL_IDX" "$TOTAL_URLS" "$CURRENT_AWEME_ID" "$LAST_STEP" "$elapsed"
    STEP_NAMES+=("$LAST_STEP")
    STEP_SECS+=("$elapsed")
  fi
  LAST_STEP="$1"
  LAST_STEP_T0=$now
  printf "[v2t %d/%d %s] %s ...\n" \
    "$CURRENT_URL_IDX" "$TOTAL_URLS" "${CURRENT_AWEME_ID:-?}" "$2"
  spin_start "$2"
}

prog_done() {
  local now elapsed
  if [ -n "$LAST_STEP" ]; then
    now=$(now_s)
    elapsed=$((now - LAST_STEP_T0))
    spin_stop
    printf "[v2t %d/%d %s] %s done in %ss\n" \
      "$CURRENT_URL_IDX" "$TOTAL_URLS" "$CURRENT_AWEME_ID" "$LAST_STEP" "$elapsed"
    STEP_NAMES+=("$LAST_STEP")
    STEP_SECS+=("$elapsed")
    LAST_STEP=""
  fi
}

fail_step() {
  # fail_step <category> <msg>
  local cat="$1" msg="$2"
  spin_stop
  echo -e "${C_RED}[v2t FAIL]${C_RST} category=${cat}  aweme_id=${CURRENT_AWEME_ID:-?}  ${msg}" >&2
  RUN_STATUS+=("fail:${cat}")
  return 1
}

# --- url + ttwid ------------------------------------------------------------

resolve_aweme_id() {
  local url="$1" id="" depth="${2:-0}"
  [ "$depth" -gt 3 ] && return 1
  id=$(echo "$url" | sed -nE 's|.*/video/([0-9]{15,}).*|\1|p')
  [ -n "$id" ] && { echo "$id"; return 0; }
  id=$(echo "$url" | sed -nE 's|.*[?&]modal_id=([0-9]{15,}).*|\1|p')
  [ -n "$id" ] && { echo "$id"; return 0; }
  if echo "$url" | grep -qE 'v\.douyin\.com|iesdouyin\.com'; then
    local final
    final=$(curl -sSL --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 1 \
      -A "$UA" -o /dev/null -w '%{url_effective}' "$url" 2>/dev/null) || final=""
    [ -n "$final" ] && [ "$final" != "$url" ] && resolve_aweme_id "$final" $((depth + 1))
    return $?
  fi
  return 1
}

bootstrap_ttwid() {
  curl -sS -X POST \
    --connect-timeout 10 --max-time 20 --retry 3 --retry-delay 2 \
    -H 'Content-Type: application/json; charset=utf-8' \
    -H "User-Agent: ${UA}" \
    -d '{"region":"cn","aid":1768,"needFid":false,"service":"www.ixigua.com","migrate_info":{"ticket":"","source":"node"},"cbUrlProtocol":"https","union":true}' \
    -D - "https://ttwid.bytedance.com/ttwid/union/register/" -o /dev/null 2>"${WORK_DIR}/ttwid.err" \
    | grep -i '^set-cookie: ttwid=' \
    | head -1 \
    | sed -E 's/.*ttwid=([^;]+).*/\1/' \
    | tr -d '\r\n'
}

# --- per-URL pipeline -------------------------------------------------------

process_one() {
  local url="$1" aweme_id canonical_url
  CURRENT_AWEME_ID=""
  LAST_STEP=""
  LAST_STEP_T0=$(now_s)
  STEP_NAMES=()
  STEP_SECS=()

  prog resolve "resolving URL → aweme_id"
  aweme_id=$(resolve_aweme_id "$url") || { fail_step parse "could not parse aweme_id from URL: $url"; return 1; }
  CURRENT_AWEME_ID="$aweme_id"
  canonical_url="https://www.douyin.com/video/${aweme_id}"

  prog ttwid "fetching anonymous ttwid cookie"
  local ttwid
  ttwid=$(bootstrap_ttwid)
  [ -n "$ttwid" ] || { fail_step douyin-network "ttwid bootstrap failed (Douyin unreachable). See ${WORK_DIR}/ttwid.err"; return 1; }

  local job_dir="${WORK_DIR}/${aweme_id}"
  mkdir -p "${job_dir}"
  cat > "${job_dir}/dy.yaml" <<EOF
douyin:
  cookie: "ttwid=${ttwid}"
  cover: false
  desc: true
  folderize: false
  interval: all
  languages: zh_CN
  lyric: false
  max_connections: 5
  max_counts: 1
  max_retries: 2
  max_tasks: 5
  mode: one
  music: false
  naming: "{aweme_id}"
  page_counts: 20
  path: "${job_dir}/dl"
  timeout: 30
  url: null
EOF

  prog download "downloading mp4 + caption via f2==${F2_VERSION}"
  local f2_log="${job_dir}/f2.log"
  if [ -n "${V2T_DEBUG:-}" ]; then
    (cd "${job_dir}" && uvx --from "f2==${F2_VERSION}" f2 dy -c "${job_dir}/dy.yaml" -M one -u "$canonical_url" 2>&1) \
      | tee "${f2_log}" || true
  else
    (cd "${job_dir}" && uvx --quiet --from "f2==${F2_VERSION}" f2 dy -c "${job_dir}/dy.yaml" -M one -u "$canonical_url" 2>&1) \
      > "${f2_log}" || true
  fi

  local mp4
  mp4=$(find "${job_dir}/dl" -name "${aweme_id}*_video.mp4" -print -quit 2>/dev/null)
  if [ -z "$mp4" ] || [ ! -f "$mp4" ]; then
    echo "[v2t] last 30 lines of f2 log (Bark notifier noise filtered):" >&2
    grep -vE 'Bark|api\.day\.app|bark_key|For more information' "${f2_log}" | tail -30 | sed 's|^|[v2t]   |' >&2
    fail_step f2-download "f2 did not produce mp4 — video likely deleted, region-locked, or login-required"
    return 1
  fi

  local desc_file desc=""
  desc_file=$(find "${job_dir}/dl" -name "${aweme_id}*_desc.txt" -print -quit 2>/dev/null)
  [ -n "$desc_file" ] && desc=$(cat "$desc_file")

  prog audio "extracting 16 kHz mono audio with ffmpeg"
  if ! ffmpeg -nostdin -loglevel error \
       -i "$mp4" -vn -acodec pcm_s16le -ar 16000 -ac 1 \
       "${job_dir}/audio.wav" -y 2>"${job_dir}/ffmpeg.log"; then
    echo "[v2t] ffmpeg stderr:" >&2
    tail -20 "${job_dir}/ffmpeg.log" | sed 's|^|[v2t]   |' >&2
    fail_step ffmpeg "audio extraction failed"
    return 1
  fi

  prog transcribe "transcribing with $(basename "$MODEL") (-p ${WHISPER_P} -t ${WHISPER_T})"
  local whisper_log="${job_dir}/whisper.log"
  local whisper_rc=0
  # --print-progress streams "[ NN%]" lines so the user sees real progress.
  # In agent mode (no TTY) it adds harmless noise to the log; cheap insurance.
  local whisper_args=(
    -m "$MODEL" -l zh
    -f "${job_dir}/audio.wav"
    --max-len 50 --entropy-thold 2.4 --no-fallback
    --print-progress
    -p "$WHISPER_P" -t "$WHISPER_T"
    -osrt -of "${job_dir}/transcript"
  )
  if [ -n "${V2T_DEBUG:-}" ]; then
    whisper-cli "${whisper_args[@]}" 2>&1 | tee "${whisper_log}"
    whisper_rc=${PIPESTATUS[0]}
  else
    whisper-cli "${whisper_args[@]}" >"${whisper_log}" 2>&1
    whisper_rc=$?
  fi
  if [ "$whisper_rc" -ne 0 ]; then
    echo "[v2t] whisper-cli log tail:" >&2
    tail -20 "${whisper_log}" | sed 's|^|[v2t]   |' >&2
    fail_step whisper "transcription failed — model corrupted? Try: rm -rf ${MODEL_DIR} && bash preflight.sh"
    return 1
  fi

  prog format "punctuating + paragraphing SRT"
  local out_txt="${OUT_DIR}/${aweme_id}.txt"
  if ! python3 "${SCRIPT_DIR}/srt_to_readable.py" \
       "${job_dir}/transcript.srt" "${out_txt}" >"${job_dir}/format.log" 2>&1; then
    cat "${job_dir}/format.log" | sed 's|^|[v2t]   |' >&2
    fail_step srt-format "srt_to_readable.py failed"
    return 1
  fi

  if [ -n "$desc" ]; then
    { echo "## desc/hashtags"; echo "$desc"; echo; echo "## transcript"; cat "${out_txt}"; } > "${out_txt}.tmp" \
      && mv "${out_txt}.tmp" "${out_txt}"
  fi

  prog_done
  printf "${C_GREEN}[v2t %d/%d %s]${C_RST} DONE → %s\n" \
    "$CURRENT_URL_IDX" "$TOTAL_URLS" "$aweme_id" "$out_txt"
  echo "----- ${aweme_id} -----"
  cat "${out_txt}"
  echo "----------"

  # Stash this URL's timing for the final summary.
  local i timing=""
  for i in "${!STEP_NAMES[@]}"; do
    timing+="${STEP_NAMES[$i]}=${STEP_SECS[$i]} "
  done
  RUN_IDS+=("$aweme_id")
  RUN_TIMING+=("${timing% }")
  RUN_STATUS+=("ok")
}

# --- summary box -----------------------------------------------------------

# Lookup timing for "step" inside "name1=N name2=M ..." string. Empty if not found.
lookup_timing() {
  local needle="$1" timing_str="$2"
  echo "$timing_str" | awk -v k="$needle" '{
    for (i=1; i<=NF; i++) {
      n = index($i, "=")
      if (n > 0 && substr($i, 1, n-1) == k) { print substr($i, n+1); exit }
    }
  }'
}

print_summary_box() {
  local total_elapsed="$1"
  local i
  local n_total="${#RUN_IDS[@]}"
  local n_failed=0
  for status in "${RUN_STATUS[@]}"; do
    [[ "$status" == fail:* ]] && n_failed=$((n_failed + 1))
  done
  local n_ok=$((n_total - n_failed))
  local hr="═════════════════════════════════════════════════════════════════════════"
  local headline
  if [ "$n_failed" -eq 0 ]; then
    headline=$(printf "${C_GREEN}✓${C_RST} douyin-video-to-text · %d/%d ok · %ds" \
                 "$n_ok" "$n_total" "$total_elapsed")
  else
    headline=$(printf "${C_RED}✗${C_RST} douyin-video-to-text · %d/%d failed · %ds" \
                 "$n_failed" "$n_total" "$total_elapsed")
  fi

  echo
  echo "${C_DIM}$hr${C_RST}"
  echo " $headline"
  echo "${C_DIM}$hr${C_RST}"
  printf "  %-19s  %4s  %4s  %5s  %5s  %5s  %5s  %5s\n" \
    "aweme_id" "rslv" "twid" "dl" "audio" "ASR" "fmt" "total"
  printf "  %-19s  %4s  %4s  %5s  %5s  %5s  %5s  %5s\n" \
    "───────────────────" "────" "────" "─────" "─────" "─────" "─────" "─────"
  for i in "${!RUN_IDS[@]}"; do
    local id="${RUN_IDS[$i]}"
    local tm="${RUN_TIMING[$i]:-}"
    local st="${RUN_STATUS[$i]:-?}"
    if [ "$st" = "ok" ]; then
      local r=$(lookup_timing resolve    "$tm")
      local t=$(lookup_timing ttwid      "$tm")
      local d=$(lookup_timing download   "$tm")
      local a=$(lookup_timing audio      "$tm")
      local w=$(lookup_timing transcribe "$tm")
      local f=$(lookup_timing format     "$tm")
      local tot=0
      for v in $r $t $d $a $w $f; do
        [ -n "$v" ] && tot=$((tot + v))
      done
      printf "  ${C_GREEN}%-19s${C_RST}  %3ss  %3ss  %4ss  %4ss  %4ss  %4ss  ${C_BOLD}%4ss${C_RST}\n" \
        "$id" "${r:-—}" "${t:-—}" "${d:-—}" "${a:-—}" "${w:-—}" "${f:-—}" "$tot"
    else
      local cat="${st#fail:}"
      printf "  ${C_RED}%-19s${C_RST}  ${C_DIM}FAILED at %s${C_RST}\n" "$id" "$cat"
    fi
  done
  echo "${C_DIM}$hr${C_RST}"
  echo "  → ${OUT_DIR}"
}

# --- main -------------------------------------------------------------------

[ "$#" -ge 1 ] || { echo "Usage: $0 <douyin_url> [<douyin_url> ...]" >&2; exit 2; }

TOTAL_URLS=$#
write_env_snapshot "$@"

run_t0=$(now_s)
rc=0
failed_ids=()
for url in "$@"; do
  CURRENT_URL_IDX=$((CURRENT_URL_IDX + 1))
  process_one "$url" || { rc=1; failed_ids+=("${CURRENT_AWEME_ID:-?}"); }
done

run_elapsed=$(( $(now_s) - run_t0 ))

# Legacy machine-parseable summary line (kept verbatim for the test harness).
echo
if [ "$rc" -eq 0 ]; then
  echo "[v2t] Processed ${TOTAL_URLS}/${TOTAL_URLS} videos in ${run_elapsed}s. Output: ${OUT_DIR}"
else
  echo "[v2t] Processed $((TOTAL_URLS - ${#failed_ids[@]}))/${TOTAL_URLS} videos in ${run_elapsed}s. Failed: ${failed_ids[*]}" >&2
fi

# Pretty boxed summary for humans.
print_summary_box "$run_elapsed"

LAST_RC=$rc
exit "$rc"
