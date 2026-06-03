#!/usr/bin/env bash
# Preflight for douyin-video-to-text (macOS only).
#
# Strategy:
#   * Brew-first: every installable dep goes through `brew install`.
#   * Parallel: brew install + HuggingFace model download run concurrently.
#   * Network-aware: auto-detects China network (Google unreachable) and
#     transparently uses Aliyun mirror for brew + Tsinghua for PyPI + hf-mirror
#     for HuggingFace. No user action needed in the happy path.
#   * Stall-aware: if a brew install exceeds $V2T_BREW_TIMEOUT seconds the
#     script kills it and prompts the user — TTY menu when interactive, native
#     macOS `osascript` dialog otherwise — to pick an alternative mirror, then
#     retries on the chosen mirror.
#   * Idempotent: re-running after success exits in <2 s.
#
# Env vars:
#   V2T_DEBUG=1                  stream live install output
#   V2T_CN_MIRROR=auto|aliyun|tuna|ustc|default
#                                force a mirror; default: auto-detect
#   V2T_BREW_TIMEOUT=<sec>       stall threshold (default 90)
#   WHISPER_MODEL_DIR=<path>     override ~/.local/share/whisper-models
#
# This skill deliberately auto-installs (departs from the Anthropic best-practice
# "check, don't install" guidance) because the first-run UX without it is bad:
# uvx f2 + a 141 MB whisper model + two brew bottles is too many manual steps.
# Reproducibility risk is bounded — every install is via brew or a uv-cached
# wheel, both reversible.

set -u
set -o pipefail

MODEL_DIR="${WHISPER_MODEL_DIR:-${HOME}/.local/share/whisper-models}"
MODEL_BASE="${MODEL_DIR}/ggml-base.bin"
MODEL_TURBO="${MODEL_DIR}/ggml-large-v3-turbo.bin"
F2_VERSION="0.0.1.7"
BREW_TIMEOUT="${V2T_BREW_TIMEOUT:-90}"

LOG_DIR="$(mktemp -d -t dy-v2t-preflight.XXXXXX)"
T0=$(date +%s)
CURRENT_MIRROR="default"
SPIN_PID=""

probe() { command -v "$1" >/dev/null 2>&1; }
log()   { printf "[preflight] %s\n" "$*" >&2; }
fail()  { spin_stop; printf "[preflight] FAIL: %s\n" "$*" >&2; exit 1; }

on_exit() {
  local rc=$?
  spin_stop
  local elapsed=$(( $(date +%s) - T0 ))
  if [ "$rc" -eq 0 ]; then
    rm -rf "$LOG_DIR"
  else
    echo >&2
    log "FAILED in ${elapsed}s. Logs kept at: $LOG_DIR"
    ls -1 "$LOG_DIR" 2>/dev/null | sed "s|^|[preflight]   |" >&2
  fi
  rm -f "${MODEL_BASE}.partial" "${MODEL_TURBO}.partial" 2>/dev/null || true
}
trap 'on_exit' EXIT INT TERM

# --- spinner (TTY-only) ------------------------------------------------------

spin_start() {
  local msg="$1"
  if [ ! -t 2 ] || [ -n "${V2T_DEBUG:-}" ]; then
    log "$msg ..."
    return
  fi
  (
    local frames="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local i=0 t0
    t0=$(date +%s)
    while :; do
      local c="${frames:$((i % 10)):1}"
      printf "\r\033[2K[preflight] %s %s (%ds)" "$c" "$msg" $(( $(date +%s) - t0 )) >&2
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

# --- mirror config -----------------------------------------------------------

apply_mirror() {
  unset HOMEBREW_API_DOMAIN HOMEBREW_BOTTLE_DOMAIN \
        HOMEBREW_BREW_GIT_REMOTE HOMEBREW_CORE_GIT_REMOTE \
        HOMEBREW_INSTALL_FROM_API \
        UV_INDEX_URL UV_DEFAULT_INDEX
  HF_BASE="https://huggingface.co"
  case "$1" in
    aliyun)
      export HOMEBREW_API_DOMAIN="https://mirrors.aliyun.com/homebrew-bottles/api"
      export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.aliyun.com/homebrew-bottles"
      export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.aliyun.com/homebrew/brew.git"
      export HOMEBREW_CORE_GIT_REMOTE="https://mirrors.aliyun.com/homebrew/homebrew-core.git"
      export HOMEBREW_INSTALL_FROM_API=1
      export UV_INDEX_URL="https://mirrors.aliyun.com/pypi/simple"
      export UV_DEFAULT_INDEX="https://mirrors.aliyun.com/pypi/simple"
      HF_BASE="https://hf-mirror.com"
      ;;
    tuna)
      export HOMEBREW_API_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api"
      export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles"
      export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/brew.git"
      export HOMEBREW_CORE_GIT_REMOTE="https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/homebrew-core.git"
      export HOMEBREW_INSTALL_FROM_API=1
      export UV_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
      export UV_DEFAULT_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"
      HF_BASE="https://hf-mirror.com"
      ;;
    ustc)
      export HOMEBREW_API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
      export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
      export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.ustc.edu.cn/brew.git"
      export HOMEBREW_INSTALL_FROM_API=1
      export UV_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
      export UV_DEFAULT_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"
      HF_BASE="https://hf-mirror.com"
      ;;
    default) ;;
    *) fail "unknown mirror: $1" ;;
  esac
  CURRENT_MIRROR="$1"
}

auto_detect_mirror() {
  case "${V2T_CN_MIRROR:-auto}" in
    aliyun|tuna|ustc|default) apply_mirror "$V2T_CN_MIRROR"; return ;;
    0) apply_mirror default; return ;;
    1) apply_mirror aliyun; return ;;
    auto)
      if curl -fsSL --connect-timeout 2 --max-time 4 -o /dev/null https://www.google.com 2>/dev/null; then
        apply_mirror default
      else
        log "China network detected — using Aliyun mirror for brew + PyPI + HuggingFace"
        apply_mirror aliyun
      fi
      ;;
    *) fail "invalid V2T_CN_MIRROR='$V2T_CN_MIRROR' (expected: auto|aliyun|tuna|ustc|default|0|1)" ;;
  esac
}

# --- interactive mirror picker -----------------------------------------------
# Returns the chosen mirror name on stdout; returns 1 if user aborts.
# Uses native macOS dialog when stdin is not a TTY; falls back to a numbered
# menu when interactive. Non-interactive non-GUI: auto-pick a fallback.

prompt_mirror_choice() {
  local cur="$CURRENT_MIRROR"
  local options=(aliyun tuna ustc default)
  # Filter out the current (failing) mirror from suggestions.
  local suggest=()
  for m in "${options[@]}"; do [ "$m" != "$cur" ] && suggest+=("$m"); done

  if [ -t 0 ]; then
    cat >&2 <<EOF

  ┌─ Homebrew is slow on '$cur' mirror ───────────┐
  │ Pick another mirror to retry:                  │
EOF
    local i=1
    for m in "${suggest[@]}"; do
      local label
      case "$m" in
        aliyun)  label="Aliyun  (mirrors.aliyun.com)        — usually fastest" ;;
        tuna)    label="Tsinghua TUNA (tuna.tsinghua.edu.cn) — academic" ;;
        ustc)    label="USTC    (mirrors.ustc.edu.cn)       — academic" ;;
        default) label="Default Homebrew CDN (overseas, no mirror)" ;;
      esac
      printf "  │   %d) %-46s│\n" "$i" "$label" >&2
      i=$((i + 1))
    done
    printf "  │   %d) Abort                                    │\n" "$i" >&2
    echo  "  └────────────────────────────────────────────────┘" >&2
    while :; do
      read -rp "[preflight] choice [1]: " choice </dev/tty
      choice="${choice:-1}"
      if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#suggest[@]}" ]; then
        echo "${suggest[$((choice - 1))]}"
        return 0
      fi
      if [ "$choice" -eq $((${#suggest[@]} + 1)) ] 2>/dev/null; then
        return 1
      fi
      log "invalid choice '$choice', try 1-$((${#suggest[@]} + 1))"
    done
  elif probe osascript; then
    # GUI dialog — user picks via macOS native list.
    local applescript_items=""
    for m in "${suggest[@]}"; do
      case "$m" in
        aliyun)  applescript_items="${applescript_items}\"Aliyun (fastest)\", " ;;
        tuna)    applescript_items="${applescript_items}\"Tsinghua TUNA\", " ;;
        ustc)    applescript_items="${applescript_items}\"USTC\", " ;;
        default) applescript_items="${applescript_items}\"Default Homebrew CDN\", " ;;
      esac
    done
    applescript_items="${applescript_items%, }"
    local picked
    picked=$(osascript <<EOF
set picked to choose from list {${applescript_items}} ¬
  with title "Homebrew slow on '${cur}' mirror" ¬
  with prompt "Pick another mirror to retry brew install:" ¬
  default items {"Aliyun (fastest)"}
if picked is false then
  return "abort"
else
  return item 1 of picked
end if
EOF
) || picked="abort"
    case "$picked" in
      *Aliyun*)   echo aliyun ;;
      *Tsinghua*) echo tuna ;;
      *USTC*)     echo ustc ;;
      *Default*)  echo default ;;
      abort|*)    return 1 ;;
    esac
  else
    # Non-TTY, no osascript: auto-fallback to next mirror in list.
    echo "${suggest[0]}"
  fi
}

# --- brew install with timeout + mirror fallback ----------------------------

brew_install_with_fallback() {
  local pkgs=("$@")
  [ "${#pkgs[@]}" -eq 0 ] && return 0
  local log="${LOG_DIR}/brew-install.log"
  local pkg_list="${pkgs[*]}"

  while :; do
    spin_start "installing ${pkg_list} via brew (${CURRENT_MIRROR} mirror)"
    if [ -n "${V2T_DEBUG:-}" ]; then
      brew install "${pkgs[@]}" 2>&1 | tee "$log" &
    else
      brew install "${pkgs[@]}" >"$log" 2>&1 &
    fi
    local pid=$!
    local waited=0 stalled=0 last_size=0

    while kill -0 "$pid" 2>/dev/null; do
      sleep 1
      waited=$((waited + 1))
      # Stall detection: if log hasn't grown in BREW_TIMEOUT seconds, abort.
      local cur_size
      cur_size=$(wc -c <"$log" 2>/dev/null || echo 0)
      if [ "$cur_size" -gt "$last_size" ]; then
        last_size="$cur_size"
        stalled=0
      else
        stalled=$((stalled + 1))
      fi
      if [ "$stalled" -ge "$BREW_TIMEOUT" ] || [ "$waited" -ge $((BREW_TIMEOUT * 3)) ]; then
        kill -TERM "$pid" 2>/dev/null
        sleep 1
        kill -KILL "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null || true
        spin_stop
        log "brew stalled for ${stalled}s (total ${waited}s) on '${CURRENT_MIRROR}'."
        log "last 8 log lines:"
        tail -8 "$log" 2>/dev/null | sed "s|^|[preflight]   |" >&2

        local new_mirror
        if new_mirror=$(prompt_mirror_choice); then
          log "switching to '${new_mirror}' mirror and retrying"
          apply_mirror "$new_mirror"
          continue 2  # re-enter outer while loop
        else
          fail "user aborted brew install"
        fi
      fi
    done

    wait "$pid"
    local rc=$?
    spin_stop
    if [ "$rc" -eq 0 ]; then
      log "✓ brew install ${pkg_list} done in ${waited}s on '${CURRENT_MIRROR}'"
      return 0
    fi
    log "brew install failed (rc=${rc}) on '${CURRENT_MIRROR}'. Last 20 lines:"
    tail -20 "$log" 2>/dev/null | sed "s|^|[preflight]   |" >&2
    local new_mirror
    if new_mirror=$(prompt_mirror_choice); then
      log "switching to '${new_mirror}' mirror and retrying"
      apply_mirror "$new_mirror"
      continue
    else
      fail "brew install failed — see ${log}"
    fi
  done
}

# --- HuggingFace model download (with retry) --------------------------------

download_model_bg() {
  local url="${HF_BASE}/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
  local log="${LOG_DIR}/model.log"
  (
    if curl -fL --connect-timeout 15 --max-time 600 --retry 3 --retry-delay 2 \
         -o "${MODEL_BASE}.partial" "$url" >"$log" 2>&1; then
      mv "${MODEL_BASE}.partial" "${MODEL_BASE}"
      echo OK >"${LOG_DIR}/model.status"
    else
      echo FAIL >"${LOG_DIR}/model.status"
    fi
  ) &
  MODEL_PID=$!
}

# --- main flow ---------------------------------------------------------------

case "$(uname -s)" in
  Darwin) ;;
  *) fail "macOS only (detected $(uname -s))" ;;
esac

probe brew || fail "Homebrew required. Install once with:
  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

auto_detect_mirror

# Decide which brew packages are missing.
brew_pkgs=()
probe uvx         || brew_pkgs+=(uv)
probe python3     || brew_pkgs+=(python)
probe ffmpeg      || brew_pkgs+=(ffmpeg)
probe whisper-cli || brew_pkgs+=(whisper-cpp)

# Start model download in parallel (only if needed).
MODEL_PID=""
mkdir -p "${MODEL_DIR}"
if [ ! -f "${MODEL_BASE}" ] && [ ! -f "${MODEL_TURBO}" ]; then
  log "downloading whisper base model (~141 MB) in background from ${HF_BASE}"
  download_model_bg
fi

# Run brew install with mirror fallback (foreground; may prompt user).
if [ "${#brew_pkgs[@]}" -gt 0 ]; then
  brew_install_with_fallback "${brew_pkgs[@]}"
fi

# Wait for model download.
if [ -n "$MODEL_PID" ]; then
  spin_start "waiting for whisper model download"
  wait "$MODEL_PID" 2>/dev/null || true
  spin_stop
  if [ "$(cat "${LOG_DIR}/model.status" 2>/dev/null)" != "OK" ]; then
    log "model download failed on '${CURRENT_MIRROR}'. Tail of model.log:"
    tail -15 "${LOG_DIR}/model.log" 2>/dev/null | sed "s|^|[preflight]   |" >&2
    fail "whisper model download failed — re-run preflight or fetch manually from ${HF_BASE}/ggerganov/whisper.cpp"
  fi
  log "✓ whisper base model ready"
fi

# Warm uvx cache for f2 (sequential — needs uv installed first).
hash -r 2>/dev/null || true
probe uvx || fail "uvx still not on PATH after brew install. Open a new terminal and re-run."
spin_start "warming uvx cache for f2==${F2_VERSION}"
if ! uvx --from "f2==${F2_VERSION}" f2 --help >"${LOG_DIR}/uvx-f2.log" 2>&1; then
  spin_stop
  tail -20 "${LOG_DIR}/uvx-f2.log" | sed "s|^|[preflight]   |" >&2
  fail "uvx f2 warm-up failed — PyPI mirror unreachable?"
fi
spin_stop

# --- summary -----------------------------------------------------------------

elapsed=$(( $(date +%s) - T0 ))
echo
echo "  ┌────────────────────────────────────────────────────────┐"
printf "  │ douyin-video-to-text preflight ready in %3ds            │\n" "$elapsed"
echo "  ├────────────────────────────────────────────────────────┤"
printf "  │ mirror      : %-40s │\n" "$CURRENT_MIRROR"
printf "  │ uv          : %-40s │\n" "$(uv --version 2>/dev/null | awk '{print $2}')"
printf "  │ python3     : %-40s │\n" "$(python3 --version 2>&1 | awk '{print $2}')"
printf "  │ ffmpeg      : %-40s │\n" "$(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}')"
printf "  │ whisper-cli : %-40s │\n" "$(brew list --versions whisper-cpp 2>/dev/null | awk '{print $2}' | head -1 || echo "installed (non-brew)")"
printf "  │ f2 (pinned) : %-40s │\n" "$F2_VERSION"
if [ -f "${MODEL_TURBO}" ]; then
  printf "  │ model       : %-40s │\n" "large-v3-turbo (1.5 GB, best quality)"
elif [ -f "${MODEL_BASE}" ]; then
  printf "  │ model       : %-40s │\n" "base (141 MB, OK quality)"
fi
echo "  └────────────────────────────────────────────────────────┘"
if [ ! -f "${MODEL_TURBO}" ]; then
  echo "  TIP: for better Mandarin quality, fetch the turbo model once:"
  echo "    curl -L --create-dirs -o ${MODEL_TURBO} \\"
  echo "      ${HF_BASE}/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
fi
