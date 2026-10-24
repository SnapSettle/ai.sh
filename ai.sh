#!/bin/sh
# ai.sh - POSIX sh AI assistant for the terminal.
# Modes: one-shot (default) and conversation (--chat / --convo).
# Requires: curl, jq (plus standard POSIX tools). See README.md and --help.

# VERSION is stamped automatically by .github/workflows/release.yml on every
# release. Do not edit it by hand ("dev" means "running from a git checkout").
VERSION="dev"
# package.nix changes this to "nix". Nix installs must never update themselves.
INSTALL_METHOD="script"
APP="ai.sh"

UPDATE_URL="${SH_AI_UPDATE_URL:-https://github.com/snapsettle/ai.sh/releases/latest/download}"

AI_DIR="${SH_AI_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ai.sh}"
CONFIG_FILE="$AI_DIR/config"
CONVO_DIR="$AI_DIR/convos"

PROVIDER_LIST="anthropic openai ollama"
CFG_VARS="CFG_PROVIDERS CFG_PROVIDER CFG_ANTHROPIC_MODEL CFG_ANTHROPIC_KEY CFG_OPENAI_MODEL CFG_OPENAI_KEY CFG_OLLAMA_HOST CFG_OLLAMA_MODEL CFG_ICONS CFG_MAX_STEPS CFG_MAX_TOKENS CFG_AUTO"

TMP_DIR=""
STTY_OFF=""
HIST=""
CONVO_ID=""
MODE="oneshot"

# =========================================================================
# Cleanup / exit handling
# =========================================================================
# shellcheck disable=SC2329  # called indirectly through the trap below
cleanup() {
  if [ -n "$STTY_OFF" ]; then stty echo 2>/dev/null; fi
  if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# =========================================================================
# Colors (truecolor with 256-color fallback, none when unsupported)
# =========================================================================
rgb() { # r g b fallback256
  if [ "$COLOR_MODE" = "true" ]; then
    printf '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"
  else
    printf '\033[38;5;%sm' "$4"
  fi
}

setup_colors() {
  COLOR_MODE="none"
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    case "${COLORTERM:-}" in
    *truecolor* | *24bit*) COLOR_MODE="true" ;;
    *)
      COLOR_MODE="256"
      if command -v tput >/dev/null 2>&1; then
        n=$(tput colors 2>/dev/null)
        case "$n" in
        '' | *[!0-9]*) ;;
        *) [ "$n" -ge 256 ] || COLOR_MODE="none" ;;
        esac
      fi
      ;;
    esac
  fi

  C_BOLD=""
  C_RESET=""
  C_TAG=""
  C_MSG=""
  C_ICON=""
  C_TEXT=""
  C_SYM=""
  C_CMD=""
  C_DIM=""
  C_OK=""
  C_WARN=""
  C_ERR=""
  C_USER=""
  C_HEAD=""
  [ "$COLOR_MODE" = "none" ] && return 0

  C_RESET=$(printf '\033[0m')
  C_BOLD=$(printf '\033[1m')
  C_TAG=$(printf '\033[1m')$(rgb 167 139 250 141)
  C_MSG=$(rgb 196 181 253 183)
  C_ICON=$(printf '\033[1m')$(rgb 34 211 238 45)
  C_TEXT=$(rgb 226 232 240 253)
  C_SYM=$(printf '\033[1m')$(rgb 251 191 36 220)
  C_CMD=$(rgb 134 239 172 121)
  C_DIM=$(rgb 113 128 150 245)
  C_OK=$(rgb 52 211 153 42)
  C_WARN=$(rgb 251 146 60 208)
  C_ERR=$(rgb 248 113 113 203)
  C_USER=$(rgb 125 211 252 117)
  C_HEAD=$(printf '\033[1m')$(rgb 244 114 182 212)
}

# =========================================================================
# Messages: [ai.sh] <message>
# =========================================================================
say() { # color text...
  c=$1
  shift
  printf '%s[%s]%s %s%s%s\n' "$C_TAG" "$APP" "$C_RESET" "$c" "$*" "$C_RESET"
}
msg() { say "$C_MSG" "$*"; }
msg_ok() { say "$C_OK" "$*"; }
msg_warn() { say "$C_WARN" "$*"; }
msg_dim() { say "$C_DIM" "$*"; }
msg_err() { say "$C_ERR" "$*" >&2; }
die() {
  msg_err "$*"
  exit 1
}

# =========================================================================
# Small helpers
# =========================================================================
uc() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
get_var() { eval "printf '%s' \"\${$1:-}\""; }
set_var() { eval "$1=\$2"; }
sq() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }
trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

cap_text() { # max chars; reads stdin
  awk -v max="$1" '{ n += length($0) + 1; if (n > max) { print "...[truncated]"; exit } print }'
}

gutter() { # prefix command output with a dim gutter (streams)
  g="${C_DIM}  | ${C_RESET}"
  awk -v g="$g" '{ print g $0; fflush() }'
}

provider_label() {
  case "$1" in
  anthropic) printf 'Anthropic' ;;
  openai) printf 'OpenAI' ;;
  ollama) printf 'Ollama' ;;
  esac
}

default_model() {
  case "$1" in
  anthropic) printf 'claude-sonnet-5-5' ;;
  openai) printf 'gpt-4o-mini' ;;
  ollama) printf 'llama3.2' ;;
  esac
}

icon_for() { # style provider
  case "$1" in
  icons)
    case "$2" in anthropic) printf '\342\234\263' ;; openai) printf '\342\234\246' ;; ollama) printf '\360\237\246\231' ;; esac
    ;;
  letters)
    case "$2" in anthropic) printf 'A>' ;; openai) printf 'O>' ;; ollama) printf 'L>' ;; esac
    ;;
  names)
    case "$2" in anthropic) printf 'claude>' ;; openai) printf 'gpt>' ;; ollama) printf 'ollama>' ;; esac
    ;;
  *)
    case "$2" in anthropic) printf '(ANT)' ;; openai) printf '(OAI)' ;; ollama) printf '(OLL)' ;; esac
    ;;
  esac
}

norm_url() {
  u=$(trim "$1")
  case "$u" in
  http://* | https://*) ;;
  *) u="http://$u" ;;
  esac
  printf '%s' "${u%/}"
}

utf8_ok() { # real icons only on UTF-8 terminals that are not a bare Linux console
  [ -t 1 ] || return 1
  case "${TERM:-dumb}" in dumb | linux) return 1 ;; esac
  loc=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
  case "$loc" in *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) return 0 ;; esac
  return 1
}

set_icon() { # sets ICON, ICON_S, ICON_PAD, CMD_PAD (icons auto on UTF-8, else text style)
  if utf8_ok; then
    ICON=$(icon_for icons "$PROVIDER")
    case "$PROVIDER" in ollama) ICON_W=2 ;; *) ICON_W=1 ;; esac
  else
    ICON=$(icon_for "$CFG_ICONS" "$PROVIDER")
    ICON_W=${#ICON}
  fi
  ICON_S="${C_ICON}${ICON}${C_RESET}"
  ICON_PAD=""
  i=0
  while [ "$i" -le "$ICON_W" ]; do
    ICON_PAD="$ICON_PAD "
    i=$((i + 1))
  done
  CMD_PAD="$ICON_PAD  "
}

# =========================================================================
# Output of model messages
#   <ICON> <RESPONSE>
#   <ICON> $ <COMMAND>
# =========================================================================
show_reply() {
  printf '%s\n' "$1" | awk -v i="$ICON_S" -v p="$ICON_PAD" -v t="$C_TEXT" -v r="$C_RESET" '
        NR == 1 { printf "%s %s%s%s\n", i, t, $0, r; next }
        { printf "%s%s%s%s\n", p, t, $0, r }'
}

show_cmd() {
  printf '%s\n' "$1" | awk -v i="$ICON_S" -v p="$CMD_PAD" -v s="$C_SYM" -v c="$C_CMD" -v r="$C_RESET" '
        NR == 1 { printf "%s %s$%s %s%s%s\n", i, s, r, c, $0, r; next }
        { printf "%s%s%s%s\n", p, c, $0, r }'
}

# =========================================================================
# Help / version
# =========================================================================
show_help() {
  cat <<EOF
ai.sh $VERSION - POSIX sh AI assistant for your terminal

USAGE
  ai.sh [options] "request"          One-shot mode (default)
  ai.sh --chat [options] ["message"] Conversation mode (chat + agent)

MODES
  One-shot   Sends your request, shows the answer or a suggested command,
             runs it after approval, then exits.
  Conversation (--convo, --chat)
             Interactive chat. The model can answer, run several commands in
             a row (seeing their output), and read or delete saved
             conversations. Inside the chat: /exit leaves (chat is kept),
             /delete leaves and deletes the active chat, /help lists commands.

OPTIONS
  -y, --y, --yolo   Toggle auto-approval of commands (flips the configured
                    default; off by default). Deleting chats always asks.
  --convo, --chat   Start conversation mode
  --temp-session    Conversation mode without saving anything to disk
  --update          Update ai.sh to the newest release (not for Nix installs,
                    Nix updates the package for you)
  --reconfig        Edit the existing configuration
  --reset           Delete everything: config and saved conversations
  --reset-config    Delete the configuration only
  --reset-convos    Delete saved conversations only
  -h, --help        Show this help
  --version         Show version

FILES (all under \$SH_AI_DIR, default: \${XDG_CACHE_HOME:-~/.cache}/ai.sh)
  config            Settings (created on first run, mode 600)
  convos/<id>.json  Saved conversations

ENVIRONMENT VARIABLES
  SH_AI_PROVIDER         Override provider: anthropic, openai, ollama
  SH_AI_MODEL            Override model name
  ANTHROPIC_API_KEY      Anthropic key (overrides the saved key)
  OPENAI_API_KEY         OpenAI key (overrides the saved key)
  OLLAMA_HOST            Ollama server URL (overrides the saved host)
  SH_AI_DIR              Override the data directory
  SH_AI_NO_UPDATE_CHECK  Set to any value to turn off the daily update notice
  SH_AI_UPDATE_URL       Where --update downloads releases from
  NO_COLOR               Disable colors
  COLORTERM              truecolor/24bit enables RGB colors, else 256-color

LABELS
  On UTF-8 terminals model messages are labeled with provider icons
  (Anthropic, OpenAI, Ollama). Elsewhere (Linux console, non-UTF-8 locale,
  piped output) the fallback text style from your config is used.

EXAMPLES
  ai.sh "list files larger than 100MB"
  ai.sh -y "show disk usage per directory"
  ai.sh "explain what the sort command does"
  ai.sh --chat
  ai.sh --chat --temp-session "help me debug this script"
  SH_AI_PROVIDER=ollama ai.sh "show listening ports"
  ai.sh --reconfig
  ai.sh --update

REQUIRED TOOLS
  curl, jq
EOF
  exit 0
}

show_version() {
  printf '%s %s\n' "$APP" "$VERSION"
  exit 0
}

chat_help() {
  msg "Chat commands: /exit or /quit = leave (chat is kept), /delete = leave and delete this chat, /help = this text."
  msg "Ask the model to list, read, or delete saved conversations."
}

# =========================================================================
# Argument parsing
# =========================================================================
setup_colors

QUERY=""
CONVO="false"
TEMP_SESSION="false"
YOLO="false"
DO_HELP="false"
DO_VERSION="false"
DO_UPDATE="false"
RESET_ALL="false"
RESET_CFG="false"
RESET_CONVOS="false"
RECONFIG="false"

add_query() {
  if [ -z "$QUERY" ]; then QUERY=$1; else QUERY="$QUERY $1"; fi
}

while [ $# -gt 0 ]; do
  case "$1" in
  -h | --help) DO_HELP="true" ;;
  --version) DO_VERSION="true" ;;
  --update) DO_UPDATE="true" ;;
  -y | --y | --yolo) YOLO="true" ;;
  --convo | --chat) CONVO="true" ;;
  --temp-session)
    TEMP_SESSION="true"
    CONVO="true"
    ;;
  --reset) RESET_ALL="true" ;;
  --reset-config) RESET_CFG="true" ;;
  --reset-convos) RESET_CONVOS="true" ;;
  --reconfig) RECONFIG="true" ;;
  --)
    shift
    while [ $# -gt 0 ]; do
      add_query "$1"
      shift
    done
    break
    ;;
  -*) die "Unknown option: $1 (see --help)" ;;
  *) add_query "$1" ;;
  esac
  shift
done

[ "$DO_HELP" = "true" ] && show_help
[ "$DO_VERSION" = "true" ] && show_version

if [ "$RESET_ALL" = "true" ] || [ "$RESET_CFG" = "true" ] || [ "$RESET_CONVOS" = "true" ] || [ "$RECONFIG" = "true" ] || [ "$DO_UPDATE" = "true" ]; then
  if [ -n "$QUERY" ] || [ "$CONVO" = "true" ]; then
    die "Reset, reconfig and update flags cannot be combined with a request or --chat."
  fi
fi

# =========================================================================
# Resets
# =========================================================================
confirm_reset() { # description
  [ "$YOLO" = "true" ] && return 0
  printf '%s[%s]%s %sThis will delete: %s. Continue? [y/N]%s ' "$C_TAG" "$APP" "$C_RESET" "$C_WARN" "$1" "$C_RESET"
  IFS= read -r a || {
    printf '\n'
    return 1
  }
  case "$a" in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

do_resets() {
  if [ "$RESET_ALL" = "true" ]; then
    RESET_CFG="true"
    RESET_CONVOS="true"
  fi
  what=""
  [ "$RESET_CFG" = "true" ] && what="configuration"
  if [ "$RESET_CONVOS" = "true" ]; then
    if [ -n "$what" ]; then what="$what and saved conversations"; else what="saved conversations"; fi
  fi
  confirm_reset "$what" || {
    msg "Cancelled. Nothing was deleted."
    exit 0
  }
  if [ "$RESET_CFG" = "true" ]; then
    rm -f "$CONFIG_FILE" "$CONFIG_FILE.new"
  fi
  if [ "$RESET_CONVOS" = "true" ]; then
    rm -rf "$CONVO_DIR"
  fi
  rmdir "$AI_DIR" 2>/dev/null
  msg_ok "Reset done: $what."
  exit 0
}

if [ "$RESET_ALL" = "true" ] || [ "$RESET_CFG" = "true" ] || [ "$RESET_CONVOS" = "true" ]; then
  do_resets
fi

# =========================================================================
# Dependency check
# =========================================================================
MISSING=""
for cmd in curl jq awk sed tr date uname cat mkdir rm mv tee head cut basename dirname sleep; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING="$MISSING $cmd"
done
if [ -n "$MISSING" ]; then
  msg_err "Missing required tools:$MISSING"
  msg_err "Please install them with your package manager and run ai.sh again."
  exit 1
fi

make_tmp() {
  TMP_DIR=$(mktemp -d 2>/dev/null)
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then return 0; fi
  TMP_DIR="${TMPDIR:-/tmp}/ai.sh.$$"
  (
    umask 077
    mkdir "$TMP_DIR"
  ) 2>/dev/null || {
    TMP_DIR=""
    die "Cannot create a temporary directory."
  }
}
make_tmp

# =========================================================================
# Updates (--update and the once-a-day "update available" notice)
#   Nix installs never update themselves: Nix replaces the whole package.
# =========================================================================
resolve_path() { # follow symlinks and print the real location of a file
  p=$1
  case "$p" in */*) ;; *) p="./$p" ;; esac
  if r=$(readlink -f "$p" 2>/dev/null) && [ -n "$r" ]; then
    printf '%s' "$r"
    return 0
  fi
  n=0
  while [ -L "$p" ] && [ "$n" -lt 20 ]; do
    t=$(readlink "$p") || break
    case "$t" in
    /*) p=$t ;;
    *) p="$(dirname "$p")/$t" ;;
    esac
    n=$((n + 1))
  done
  printf '%s' "$p"
}

is_nix_install() {
  [ "$INSTALL_METHOD" = "nix" ] && return 0
  case "$(resolve_path "$0")" in /nix/store/*) return 0 ;; esac
  return 1
}

valid_version() { # digits and dots only, starting with a digit
  case "$1" in '' | *[!0-9.]* | .*) return 1 ;; esac
  return 0
}

ver_newer() { # latest current -> success if latest is newer than current
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, ".")
    n = (na > nb) ? na : nb
    for (i = 1; i <= n; i++) {
      if ((x[i] + 0) > (y[i] + 0)) exit 0
      if ((x[i] + 0) < (y[i] + 0)) exit 1
    }
    exit 1
  }'
}

latest_version() { # [connect-timeout] [max-time] -> prints the newest released version
  v=$(curl -fsSL --connect-timeout "${1:-5}" --max-time "${2:-15}" "$UPDATE_URL/VERSION" 2>/dev/null | head -n 1 | tr -d '[:space:]')
  valid_version "$v" || return 1
  printf '%s' "$v"
}

sha256_of() { # file -> prints the SHA-256 hash
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r "$1" | awk '{ print $1 }'
  else
    return 1
  fi
}

do_update() {
  if is_nix_install; then
    msg_warn "This copy of ai.sh was installed by Nix, so it must not update itself."
    msg "Nix updates it for you when you rebuild:"
    msg "  Flake users:      nix flake update ai-sh   then   sudo nixos-rebuild switch --flake ."
    msg "  Non-flake users:  sudo nixos-rebuild switch"
    exit 0
  fi

  self=$(resolve_path "$0")
  [ -f "$self" ] || die "Cannot find the ai.sh file to update (looked for: $self)."
  selfdir=$(dirname "$self")
  if [ ! -w "$self" ] || [ ! -w "$selfdir" ]; then
    die "No permission to change $self. Re-run with sudo, or reinstall to a folder you own."
  fi

  msg "Checking for updates..."
  latest=$(latest_version 5 15) || die "Could not check for updates. Are you online?"
  if [ "$VERSION" != "dev" ] && ! ver_newer "$latest" "$VERSION"; then
    msg_ok "Already up to date ($VERSION)."
    exit 0
  fi

  msg "Downloading version $latest..."
  curl -fsSL --connect-timeout 10 --max-time 60 "$UPDATE_URL/ai.sh" -o "$TMP_DIR/ai.sh.new" ||
    die "Download failed."
  curl -fsSL --connect-timeout 10 --max-time 60 "$UPDATE_URL/ai.sh.sha256" -o "$TMP_DIR/ai.sh.sha256" ||
    die "Could not download the checksum file."

  want=$(awk '{ print $1; exit }' "$TMP_DIR/ai.sh.sha256")
  got=$(sha256_of "$TMP_DIR/ai.sh.new") || die "No sha256sum, shasum or openssl found, cannot verify the download."
  [ -n "$want" ] && [ "$want" = "$got" ] || die "Checksum mismatch. The download was not installed."
  sh -n "$TMP_DIR/ai.sh.new" 2>/dev/null || die "The downloaded file is not a valid script. Nothing was installed."
  new_ver=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$TMP_DIR/ai.sh.new" | head -n 1)
  valid_version "$new_ver" || die "The downloaded file has no valid version. Nothing was installed."

  if ! { cp "$TMP_DIR/ai.sh.new" "$self.new" && chmod 755 "$self.new" && mv "$self.new" "$self"; }; then
    rm -f "$self.new"
    die "Could not replace $self."
  fi
  msg_ok "Updated: $VERSION -> $new_ver"
  exit 0
}

update_notice() { # at most one quick check per day, interactive terminals only
  if [ "$VERSION" = "dev" ] || [ "$TEMP_SESSION" = "true" ] || [ -n "${SH_AI_NO_UPDATE_CHECK:-}" ]; then
    return 0
  fi
  if [ ! -t 0 ] || [ ! -t 1 ]; then return 0; fi
  if is_nix_install; then return 0; fi

  stamp="$AI_DIR/update-check"
  now=$(date +%s)
  last=0
  seen=""
  if [ -f "$stamp" ]; then read -r last seen <"$stamp" 2>/dev/null; fi
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -ge 86400 ]; then
    seen=$(latest_version 2 4) || seen=""
    (
      umask 077
      mkdir -p "$AI_DIR" && printf '%s %s\n' "$now" "$seen" >"$stamp"
    ) 2>/dev/null
  fi
  if valid_version "$seen" && ver_newer "$seen" "$VERSION"; then
    msg_warn "Update available: $VERSION -> $seen. Run: ai.sh --update"
  fi
  return 0
}

if [ "$DO_UPDATE" = "true" ]; then
  do_update
fi

# =========================================================================
# Configuration: defaults, load, save
# =========================================================================
# shellcheck disable=SC2034  # the CFG_* values are read indirectly via get_var / CFG_VARS
set_defaults() {
  CFG_PROVIDERS=""
  CFG_PROVIDER=""
  CFG_ANTHROPIC_MODEL=$(default_model anthropic)
  CFG_ANTHROPIC_KEY=""
  CFG_OPENAI_MODEL=$(default_model openai)
  CFG_OPENAI_KEY=""
  CFG_OLLAMA_HOST="http://localhost:11434"
  CFG_OLLAMA_MODEL=$(default_model ollama)
  CFG_ICONS="tags"
  CFG_MAX_STEPS="10"
  CFG_MAX_TOKENS="1024"
  CFG_AUTO="false"
}

load_config() {
  set_defaults
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
  case "$CFG_MAX_STEPS" in '' | *[!0-9]* | 0) CFG_MAX_STEPS=10 ;; esac
  case "$CFG_MAX_TOKENS" in '' | *[!0-9]* | 0) CFG_MAX_TOKENS=1024 ;; esac
  case "$CFG_ICONS" in letters | names | tags) ;; *) CFG_ICONS="tags" ;; esac
  case "$CFG_AUTO" in true | false) ;; *) CFG_AUTO="false" ;; esac
}

save_config() {
  (
    umask 077
    mkdir -p "$AI_DIR"
  ) || die "Cannot create $AI_DIR."
  if ! (
    umask 077
    {
      printf '# ai.sh configuration (generated). Change it with: ai.sh --reconfig\n'
      for v in $CFG_VARS; do
        printf "%s='%s'\n" "$v" "$(sq "$(get_var "$v")")"
      done
    } >"$CONFIG_FILE.new"
  ); then
    die "Could not write $CONFIG_FILE."
  fi
  mv "$CONFIG_FILE.new" "$CONFIG_FILE" || die "Could not write $CONFIG_FILE."
}

# =========================================================================
# Configuration mode (interactive)
# =========================================================================
ask() { # label default -> ANS
  if [ -n "$2" ]; then
    printf '  %s%s%s %s[%s]%s: ' "$C_USER" "$1" "$C_RESET" "$C_DIM" "$2" "$C_RESET"
  else
    printf '  %s%s%s: ' "$C_USER" "$1" "$C_RESET"
  fi
  IFS= read -r ANS || {
    printf '\n'
    die "Input closed. Nothing saved."
  }
  ANS=$(trim "$ANS")
  [ -n "$ANS" ] || ANS=$2
}

ask_yn() { # label default(y|n) -> YN
  while :; do
    ask "$1 (y/n)" "$2"
    case "$ANS" in
    [yY] | [yY][eE][sS])
      YN="y"
      return 0
      ;;
    [nN] | [nN][oO])
      YN="n"
      return 0
      ;;
    *) msg_warn "Please answer y or n." ;;
    esac
  done
}

ask_num() { # label default -> NUM
  while :; do
    ask "$1" "$2"
    case "$ANS" in
    '' | *[!0-9]* | 0) msg_warn "Enter a positive whole number." ;;
    *)
      NUM=$ANS
      return 0
      ;;
    esac
  done
}

read_secret() { # label hint -> ANS (not echoed, not trimmed)
  printf '  %s%s%s %s(%s)%s: ' "$C_USER" "$1" "$C_RESET" "$C_DIM" "$2" "$C_RESET"
  if [ -t 0 ] && stty -echo 2>/dev/null; then STTY_OFF="1"; fi
  IFS= read -r ANS
  rc=$?
  if [ -n "$STTY_OFF" ]; then
    stty echo 2>/dev/null
    STTY_OFF=""
  fi
  printf '\n'
  [ "$rc" -eq 0 ] || die "Input closed. Nothing saved."
}

show_tips() { # provider
  printf '\n'
  case "$1" in
  anthropic)
    msg "Tips for Anthropic:"
    msg "  1. Create an API key at https://console.anthropic.com/settings/keys"
    msg "  2. Either paste it here, or export ANTHROPIC_API_KEY in your shell profile"
    msg "     and just press return to use it."
    msg "  3. Model names are listed at https://docs.claude.com (e.g. claude-sonnet-5-5)."
    ;;
  openai)
    msg "Tips for OpenAI:"
    msg "  1. Create an API key at https://platform.openai.com/api-keys"
    msg "  2. Either paste it here, or export OPENAI_API_KEY in your shell profile"
    msg "     and just press return to use it."
    msg "  3. Cheap, fast default model: gpt-4o-mini."
    ;;
  ollama)
    msg "Tips for Ollama (local, no API key):"
    msg "  1. Install it from https://ollama.com and start it: ollama serve"
    msg "  2. Download a model: ollama pull llama3.2"
    msg "  3. Default host is http://localhost:11434 (also set via OLLAMA_HOST)."
    ;;
  esac
  printf '\n'
}

ask_p() { # label default -> ANS ; handles ? (tips) and q (quit provider)
  while :; do
    ask "$1" "$2"
    case "$ANS" in
    q | Q) return 1 ;;
    '?') show_tips "$CUR_P" ;;
    *) return 0 ;;
    esac
  done
}

ask_key() { # provider -> NEWKEY ; return 1 on quit
  p=$1
  CUR_P=$p
  envname="$(uc "$p")_API_KEY"
  cur_key=$(get_var "CFG_$(uc "$p")_KEY")
  envkey=$(get_var "$envname")
  if [ -n "$envkey" ]; then
    hint="return = keep / use \$$envname"
  elif [ -n "$cur_key" ]; then
    hint="return = keep saved key"
  else hint="required"; fi
  while :; do
    read_secret "$(provider_label "$p") API key" "$hint, ? tips, q quit"
    case "$ANS" in
    q | Q) return 1 ;;
    '?') show_tips "$p" ;;
    '')
      if [ -n "$envkey" ] || [ -n "$cur_key" ]; then
        NEWKEY=$cur_key
        return 0
      fi
      msg_warn "A key is required (or type q to skip this provider)."
      ;;
    *)
      NEWKEY=$ANS
      return 0
      ;;
    esac
  done
}

pick_ollama_model() { # host default -> NEWMODEL ; return 1 on quit
  CUR_P="ollama"
  models=""
  if tags=$(curl -sS --connect-timeout 3 --max-time 8 "$1/api/tags" 2>/dev/null); then
    models=$(printf '%s' "$tags" | jq -r '.models[]?.name' 2>/dev/null)
  fi
  if [ -n "$models" ]; then
    msg "Local Ollama models found:"
    n=0
    d=""
    for m in $models; do
      n=$((n + 1))
      printf '    %s) %s\n' "$n" "$m"
      [ "$n" -eq 1 ] && d=$m
      [ "$m" = "$2" ] && d=$m
    done
    ask_p "Model (number or name)" "$d" || return 1
    case "$ANS" in
    '' | *[!0-9]*) NEWMODEL=$ANS ;;
    *)
      NEWMODEL=$(printf '%s\n' "$models" | sed -n "${ANS}p")
      [ -n "$NEWMODEL" ] || NEWMODEL=$ANS
      ;;
    esac
  else
    msg_warn "Could not list models from $1 (is Ollama running?). Enter a name manually."
    ask_p "Model name" "$2" || return 1
    NEWMODEL=$ANS
  fi
}

setup_provider() { # provider -> 0 configured, 1 skipped
  p=$1
  U=$(uc "$p")
  CUR_P=$p
  label=$(provider_label "$p")
  printf '\n'
  msg "Configuring $label  ('?' = tips, 'q' = quit this provider)"
  case "$p" in
  anthropic | openai)
    ask_key "$p" || return 1
    key=$NEWKEY
    cur_model=$(get_var "CFG_${U}_MODEL")
    ask_p "$label model" "${cur_model:-$(default_model "$p")}" || return 1
    model=$ANS
    set_var "CFG_${U}_KEY" "$key"
    set_var "CFG_${U}_MODEL" "$model"
    ;;
  ollama)
    ask_p "Ollama host" "${CFG_OLLAMA_HOST:-http://localhost:11434}" || return 1
    host=$(norm_url "$ANS")
    pick_ollama_model "$host" "$CFG_OLLAMA_MODEL" || return 1
    CFG_OLLAMA_HOST=$host
    CFG_OLLAMA_MODEL=$NEWMODEL
    ;;
  esac
  return 0
}

setup_providers() {
  msg "Providers: choose the AI services you want to use."
  while :; do
    new=""
    for p in $PROVIDER_LIST; do
      case " $CFG_PROVIDERS " in *" $p "*) d="y" ;; *) d="n" ;; esac
      if [ -z "$CFG_PROVIDERS" ] && [ "$p" = "anthropic" ]; then d="y"; fi
      ask_yn "Use $(provider_label "$p")?" "$d"
      if [ "$YN" = "y" ]; then
        if setup_provider "$p"; then
          new="$new $p"
        else
          msg_warn "$(provider_label "$p") skipped."
        fi
      fi
    done
    new=${new# }
    [ -n "$new" ] && break
    msg_warn "At least one provider is required. Let's try again (Ctrl-C to abort)."
  done
  CFG_PROVIDERS=$new
}

choose_preferred() {
  # shellcheck disable=SC2086  # splitting the provider list into separate words is intended
  set -- $CFG_PROVIDERS
  if [ $# -le 1 ]; then
    CFG_PROVIDER=$1
    return 0
  fi
  d=1
  n=0
  printf '\n'
  msg "More than one provider is configured. Pick your preferred one:"
  for p in "$@"; do
    n=$((n + 1))
    printf '    %s) %s\n' "$n" "$p"
    [ "$p" = "$CFG_PROVIDER" ] && d=$n
  done
  while :; do
    ask "Preferred provider (1-$#)" "$d"
    case "$ANS" in '' | *[!0-9]*)
      msg_warn "Enter a number from the list."
      continue
      ;;
    esac
    if [ "$ANS" -ge 1 ] && [ "$ANS" -le $# ]; then
      eval "CFG_PROVIDER=\${$ANS}"
      return 0
    fi
    msg_warn "Enter a number from the list."
  done
}

choose_icons() {
  case "${CFG_ICONS:-tags}" in letters) d=1 ;; names) d=2 ;; *) d=3 ;; esac
  printf '\n'
  msg "Fallback label style. On UTF-8 terminals icons are used automatically; this style is used on TTYs and other terminals without icon support:"
  printf '    1) letters   A> = Anthropic   O> = OpenAI   L> = Ollama\n'
  printf '    2) names     claude> = Anthropic   gpt> = OpenAI   ollama> = Ollama\n'
  printf '    3) tags      (ANT) = Anthropic   (OAI) = OpenAI   (OLL) = Ollama\n'
  while :; do
    ask "Style (1-3)" "$d"
    case "$ANS" in
    1 | letters)
      CFG_ICONS="letters"
      return 0
      ;;
    2 | names)
      CFG_ICONS="names"
      return 0
      ;;
    3 | tags)
      CFG_ICONS="tags"
      return 0
      ;;
    *) msg_warn "Enter 1, 2 or 3." ;;
    esac
  done
}

key_state() { # provider
  k=$(get_var "CFG_$(uc "$1")_KEY")
  e=$(get_var "$(uc "$1")_API_KEY")
  if [ -n "$k" ]; then
    printf 'saved (hidden)'
  elif [ -n "$e" ]; then
    printf 'from $%s_API_KEY' "$(uc "$1")"
  else printf 'MISSING'; fi
}

ROW_N=0
add_row() { # key label value
  ROW_N=$((ROW_N + 1))
  set_var "ROW_$ROW_N" "$1"
  printf '  %s%-3s%s %-22s %s%s%s\n' "$C_SYM" "$ROW_N" "$C_RESET" "$2" "$C_TEXT" "$3" "$C_RESET"
}

show_summary() {
  ROW_N=0
  printf '\n'
  msg "Configuration summary"
  printf '  %s%-3s %-22s %s%s\n' "$C_HEAD" "#" "Setting" "Value" "$C_RESET"
  printf '  %s%s%s\n' "$C_DIM" "-----------------------------------------------------" "$C_RESET"
  add_row CFG_PROVIDERS "Providers" "$CFG_PROVIDERS"
  add_row CFG_PROVIDER "Preferred provider" "$CFG_PROVIDER"
  for p in $CFG_PROVIDERS; do
    U=$(uc "$p")
    case "$p" in
    ollama)
      add_row CFG_OLLAMA_HOST "Ollama host" "$CFG_OLLAMA_HOST"
      add_row CFG_OLLAMA_MODEL "Ollama model" "$CFG_OLLAMA_MODEL"
      ;;
    *)
      add_row "CFG_${U}_MODEL" "$(provider_label "$p") model" "$(get_var "CFG_${U}_MODEL")"
      add_row "CFG_${U}_KEY" "$(provider_label "$p") API key" "$(key_state "$p")"
      ;;
    esac
  done
  prev=""
  for p in $CFG_PROVIDERS; do prev="$prev $p=$(icon_for "$CFG_ICONS" "$p")"; done
  add_row CFG_ICONS "Fallback label style" "$CFG_ICONS  ($(trim "$prev"))"
  add_row CFG_MAX_STEPS "Max steps/request" "$CFG_MAX_STEPS"
  add_row CFG_MAX_TOKENS "Max reply tokens" "$CFG_MAX_TOKENS"
  add_row CFG_AUTO "Auto-approve default" "$CFG_AUTO"
  printf '\n'
}

edit_row() { # row number
  k=$(get_var "ROW_$1")
  case "$k" in
  CFG_PROVIDERS)
    setup_providers
    case " $CFG_PROVIDERS " in *" $CFG_PROVIDER "*) ;; *) CFG_PROVIDER="" ;; esac
    choose_preferred
    ;;
  CFG_PROVIDER) choose_preferred ;;
  CFG_OLLAMA_HOST)
    CUR_P="ollama"
    if ask_p "Ollama host" "$CFG_OLLAMA_HOST"; then CFG_OLLAMA_HOST=$(norm_url "$ANS"); fi
    ;;
  CFG_OLLAMA_MODEL)
    if pick_ollama_model "$CFG_OLLAMA_HOST" "$CFG_OLLAMA_MODEL"; then CFG_OLLAMA_MODEL=$NEWMODEL; fi
    ;;
  CFG_ANTHROPIC_MODEL | CFG_OPENAI_MODEL)
    p=$(lc "${k#CFG_}")
    p=${p%_model}
    CUR_P=$p
    if ask_p "$(provider_label "$p") model" "$(get_var "$k")"; then set_var "$k" "$ANS"; fi
    ;;
  CFG_ANTHROPIC_KEY | CFG_OPENAI_KEY)
    p=$(lc "${k#CFG_}")
    p=${p%_key}
    if ask_key "$p"; then set_var "$k" "$NEWKEY"; fi
    ;;
  CFG_ICONS) choose_icons ;;
  CFG_MAX_STEPS)
    ask_num "Max steps per request" "$CFG_MAX_STEPS"
    CFG_MAX_STEPS=$NUM
    ;;
  CFG_MAX_TOKENS)
    ask_num "Max reply tokens" "$CFG_MAX_TOKENS"
    CFG_MAX_TOKENS=$NUM
    ;;
  CFG_AUTO)
    if [ "$CFG_AUTO" = "true" ]; then d="y"; else d="n"; fi
    ask_yn "Auto-approve commands by default?" "$d"
    if [ "$YN" = "y" ]; then CFG_AUTO="true"; else CFG_AUTO="false"; fi
    ;;
  esac
}

run_config() {
  [ -t 0 ] || die "Configuration needs an interactive terminal."
  printf '\n'
  msg "Configuration mode. Press return to accept the [default] shown."
  setup_providers
  choose_preferred
  if utf8_ok; then
    printf '\n'
    msg "Provider icons will be used on this terminal. Fallback text labels (for TTYs/pipes) default to tags; change them via the summary table."
  else
    choose_icons
  fi
  printf '\n'
  msg "General settings"
  ask_num "Max steps per request" "$CFG_MAX_STEPS"
  CFG_MAX_STEPS=$NUM
  ask_num "Max reply tokens" "$CFG_MAX_TOKENS"
  CFG_MAX_TOKENS=$NUM
  if [ "$CFG_AUTO" = "true" ]; then d="y"; else d="n"; fi
  ask_yn "Auto-approve commands by default?" "$d"
  if [ "$YN" = "y" ]; then CFG_AUTO="true"; else CFG_AUTO="false"; fi

  while :; do
    show_summary
    ask "Save? [y]es / [e]dit / [q]uit" "y"
    case "$ANS" in
    y | Y | yes)
      save_config
      msg_ok "Configuration saved to $CONFIG_FILE"
      return 0
      ;;
    e | E | edit)
      ask "Row number to edit (return to cancel)" ""
      case "$ANS" in
      '') ;;
      *[!0-9]*) msg_warn "Enter a row number." ;;
      *)
        if [ "$ANS" -ge 1 ] && [ "$ANS" -le "$ROW_N" ]; then
          edit_row "$ANS"
        else msg_warn "No such row."; fi
        ;;
      esac
      ;;
    q | Q | quit) die "Configuration cancelled. Nothing saved." ;;
    *) msg_warn "Answer y, e or q." ;;
    esac
  done
}

# =========================================================================
# First-launch banner
# =========================================================================
show_banner() {
  n=0
  printf '\n'
  while IFS= read -r line; do
    n=$((n + 1))
    case "$n" in
    1) c=$(rgb 167 139 250 141) ;;
    2) c=$(rgb 137 150 246 105) ;;
    3) c=$(rgb 107 160 244 69) ;;
    4) c=$(rgb 70 185 240 75) ;;
    *) c=$(rgb 34 211 238 45) ;;
    esac
    printf '  %s%s%s%s\n' "$C_BOLD" "$c" "$line" "$C_RESET"
  done <<'BANNER'
        _          _
  __ _ (_)    ___ | |__
 / _` || |   / __|| '_ \
| (_| || | _ \__ \| | | |
 \__,_||_|(_)|___/|_| |_|
BANNER
  printf '\n  %sPOSIX sh AI assistant  -  v%s%s\n' "$C_DIM" "$VERSION" "$C_RESET"
  printf '  %sOne-shot + chat  |  Anthropic, OpenAI, Ollama%s\n\n' "$C_DIM" "$C_RESET"
}

# =========================================================================
# Load or create the configuration
# =========================================================================
if [ "$RECONFIG" = "true" ]; then
  load_config
  run_config
  exit 0
fi

if [ ! -f "$CONFIG_FILE" ]; then
  [ -t 0 ] || die "No configuration found. Run ai.sh in an interactive terminal to set it up."
  set_defaults
  show_banner
  msg "No configuration found. Let's set ai.sh up first."
  run_config
  if [ -z "$QUERY" ] && [ "$CONVO" != "true" ]; then
    msg 'Setup complete. Try: ai.sh "your request" or ai.sh --chat (see --help).'
    exit 0
  fi
fi

load_config
[ -n "$CFG_PROVIDERS" ] || die "Configuration is incomplete. Run: ai.sh --reconfig"

# =========================================================================
# Resolve runtime settings
# =========================================================================
PROVIDER=${SH_AI_PROVIDER:-$CFG_PROVIDER}
[ -n "$PROVIDER" ] || PROVIDER=${CFG_PROVIDERS%% *}
case " $PROVIDER_LIST " in
*" $PROVIDER "*) ;;
*) die "Unknown provider '$PROVIDER'. Use one of: $PROVIDER_LIST" ;;
esac

MODEL=${SH_AI_MODEL:-$(get_var "CFG_$(uc "$PROVIDER")_MODEL")}
[ -n "$MODEL" ] || MODEL=$(default_model "$PROVIDER")

MAX_TOKENS=$CFG_MAX_TOKENS
STEPS_LIMIT=$CFG_MAX_STEPS

AUTO=$CFG_AUTO
if [ "$YOLO" = "true" ]; then
  if [ "$AUTO" = "true" ]; then AUTO="false"; else AUTO="true"; fi
fi

set_icon
update_notice

# =========================================================================
# Master prompt (one prompt for every mode)
# =========================================================================
build_prompt() {
  OS_INFO=$(uname -s)
  CWD=$(pwd)
  USER_NAME=${USER:-$(id -un 2>/dev/null)}
  if [ "$MODE" = "convo" ]; then
    if [ "$TEMP_SESSION" = "true" ]; then sess="temporary (not saved)"; else sess="saved as $CONVO_ID"; fi
    MODE_DESC="conversation (session $sess). You may run several commands in a row. After each command you receive its output and exit status, then continue or finish with ANSWER:."
  else
    MODE_DESC="one-shot. Your single reply is shown to the user. You will NOT see command output, so reply with a command for command tasks and with ANSWER: for questions."
  fi

  SYSTEM_PROMPT="You are ai.sh, an assistant embedded in the user's POSIX shell terminal. You can chat and you can run shell commands for the user.

REPLY FORMAT (reply with exactly one of these, in plain text, no markdown, no code fences, no greetings):
1. A shell command: output ONLY the POSIX sh command (a single command or a valid pipeline/chain, multi-line only when needed). The user approves it before it runs.
2. ANSWER: followed by your message. Use it for conversation, explanations and your final answer after running commands.
3. INTERNAL: list | INTERNAL: show <id> | INTERNAL: delete <id>. Conversation mode only. These list, read or delete the user's saved conversations.

RULES:
- Use strict POSIX sh syntax. No bashisms such as [[ ]], arrays, source or process substitution.
- Do not output interactive commands unless explicitly requested.
- Prefer minimal and safe commands. Never run destructive commands unless explicitly asked.
- Any reply that does not start with ANSWER: or INTERNAL: is treated as a shell command.
- Keep ANSWER replies short and clear.
- Each command runs in a fresh shell, so cd and export do not carry over to the next command. Chain steps with && or use full paths.

EXAMPLES:
User: list all files larger than 100MB
Reply: find . -type f -size +100M
User: what does the sort command do?
Reply: ANSWER: sort orders lines of text. Use -n for numbers and -r to reverse.
User: show my saved conversations
Reply: INTERNAL: list

MODE: $MODE_DESC
ENVIRONMENT: OS=$OS_INFO USER=$USER_NAME CWD=$CWD"
}

# =========================================================================
# History
# =========================================================================
hist_add() { # role content
  [ -f "$HIST" ] || (
    umask 077
    printf '[]\n' >"$HIST"
  ) || return 1
  (
    umask 077
    jq --arg r "$1" --arg c "$2" '. + [{role: $r, content: $c}]' "$HIST" >"$HIST.new"
  ) &&
    mv "$HIST.new" "$HIST"
}

# =========================================================================
# Model call (sets REPLY)
# =========================================================================
curl_cfg() { # header lines -> curl config on stdout (keeps keys out of ps)
  for h in "$@"; do
    esc=$(printf '%s' "$h" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf 'header = "%s"\n' "$esc"
  done
}

should_retry() { # curl-exit-code response -> success if the problem is probably temporary
  case "$1" in
  0) ;;
  28 | 35 | 52 | 55 | 56) return 0 ;;
  *) return 1 ;;
  esac
  printf '%s' "$2" | jq -e '[(.error.type? // ""), (.error.code? // "")] | map(tostring) | any(test("overloaded|rate_limit|server_error|api_error"))' >/dev/null 2>&1
}

call_model() {
  REPLY=""
  PAYLOAD="$TMP_DIR/payload.json"
  case "$PROVIDER" in
  anthropic)
    API_KEY=${ANTHROPIC_API_KEY:-$CFG_ANTHROPIC_KEY}
    [ -n "$API_KEY" ] || {
      msg_err "No Anthropic API key. Set ANTHROPIC_API_KEY or run: ai.sh --reconfig"
      return 1
    }
    URL="https://api.anthropic.com/v1/messages"
    HDRS=$(curl_cfg "x-api-key: $API_KEY" "anthropic-version: 2023-06-01" "content-type: application/json")
    jq -n --arg model "$MODEL" --arg sys "$SYSTEM_PROMPT" --argjson max "$MAX_TOKENS" --slurpfile m "$HIST" \
      '{model: $model, max_tokens: $max, system: $sys, messages: $m[0]}' >"$PAYLOAD"
    FILTER='[.content[]? | select(.type == "text") | .text] | join("")'
    ;;
  openai)
    API_KEY=${OPENAI_API_KEY:-$CFG_OPENAI_KEY}
    [ -n "$API_KEY" ] || {
      msg_err "No OpenAI API key. Set OPENAI_API_KEY or run: ai.sh --reconfig"
      return 1
    }
    URL="https://api.openai.com/v1/chat/completions"
    HDRS=$(curl_cfg "Authorization: Bearer $API_KEY" "Content-Type: application/json")
    jq -n --arg model "$MODEL" --arg sys "$SYSTEM_PROMPT" --argjson max "$MAX_TOKENS" --slurpfile m "$HIST" \
      '{model: $model, max_completion_tokens: $max, messages: ([{role: "system", content: $sys}] + $m[0])}' >"$PAYLOAD"
    FILTER='.choices[0].message.content // empty'
    ;;
  ollama)
    OLLAMA_URL=$(norm_url "${OLLAMA_HOST:-${CFG_OLLAMA_HOST:-http://localhost:11434}}")
    URL="$OLLAMA_URL/api/chat"
    HDRS=$(curl_cfg "Content-Type: application/json")
    jq -n --arg model "$MODEL" --arg sys "$SYSTEM_PROMPT" --argjson max "$MAX_TOKENS" --slurpfile m "$HIST" \
      '{model: $model, stream: false, options: {temperature: 0.1, num_predict: $max}, messages: ([{role: "system", content: $sys}] + $m[0])}' >"$PAYLOAD"
    FILTER='.message.content // empty'
    ;;
  esac
  [ -s "$PAYLOAD" ] || {
    msg_err "Failed to build the request."
    return 1
  }

  attempt=1
  while :; do
    if [ -t 1 ]; then printf '%s%s%s' "$C_DIM" "thinking..." "$C_RESET"; fi
    RESP=$(printf '%s\n' "$HDRS" | curl -sS --connect-timeout 15 --max-time 180 -K - -X POST "$URL" \
      --data-binary "@$PAYLOAD" 2>"$TMP_DIR/curl.err")
    rc=$?
    if [ -t 1 ]; then printf '\r\033[K'; fi
    if [ "$attempt" -lt 3 ] && should_retry "$rc" "$RESP"; then
      msg_dim "Temporary problem, trying again ($attempt/2)..."
      sleep $((attempt * 2))
      attempt=$((attempt + 1))
      continue
    fi
    break
  done

  if [ "$rc" -ne 0 ]; then
    msg_err "Request failed (curl exit $rc): $(head -n 1 "$TMP_DIR/curl.err" 2>/dev/null)"
    return 1
  fi

  REPLY=$(printf '%s' "$RESP" | jq -r "$FILTER" 2>/dev/null)
  if [ -z "$REPLY" ]; then
    err=$(printf '%s' "$RESP" | jq -r 'if (.error | type) == "object" then .error.message elif (.error | type) == "string" then .error else (.message // empty) end' 2>/dev/null)
    if [ -n "$err" ]; then
      msg_err "API error: $err"
    else
      msg_err "The model returned no usable reply."
    fi
    return 1
  fi

  # Strip stray markdown fences and leading blank lines
  REPLY=$(printf '%s\n' "$REPLY" | sed -e '/^[[:space:]]*```/d' -e '/./,$!d')
  [ -n "$REPLY" ] || {
    msg_err "The model returned an empty reply."
    return 1
  }
  return 0
}

# =========================================================================
# Approval and command execution
# =========================================================================
approve() { # question [force]  ("force" asks even in auto-approve mode)
  if [ "$AUTO" = "true" ] && [ "$2" != "force" ]; then
    msg_warn "Auto-approved (yolo)."
    return 0
  fi
  printf '%s[%s]%s %s%s [y/N]%s ' "$C_TAG" "$APP" "$C_RESET" "$C_WARN" "$1" "$C_RESET"
  IFS= read -r ans || {
    printf '\n'
    return 1
  }
  case "$ans" in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

run_cmd() { # command -> CMD_RC, CMD_OUT
  OUT_FILE="$TMP_DIR/cmd.out"
  RC_FILE="$TMP_DIR/cmd.rc"
  : >"$OUT_FILE"
  {
    sh -c "$1" </dev/null 2>&1
    printf '%s\n' "$?" >"$RC_FILE"
  } | tee "$OUT_FILE" | gutter
  CMD_RC=$(cat "$RC_FILE" 2>/dev/null)
  [ -n "$CMD_RC" ] || CMD_RC=1
  if [ ! -s "$OUT_FILE" ]; then msg_dim "(no output)"; fi
  if [ "$CMD_RC" -eq 0 ]; then msg_ok "Done (exit 0)."; else msg_err "Exited with status $CMD_RC."; fi
  CMD_OUT=$(cap_text 20000 <"$OUT_FILE")
}

# =========================================================================
# Internal commands (conversation mode): list / show / delete
# =========================================================================
valid_id() {
  case "$1" in '' | *[!A-Za-z0-9_-]*) return 1 ;; esac
  return 0
}

internal_cmd() { # "list" | "show <id>" | "delete <id>" -> INT_OUT
  INT_OUT=""
  act=$(lc "${1%% *}")
  arg=$(trim "${1#"${1%% *}"}")
  case "$act" in
  list)
    msg_dim "Model: listing saved conversations"
    found=0
    for f in "$CONVO_DIR"/*.json; do
      [ -f "$f" ] || continue
      found=1
      id=$(basename "$f" .json)
      cnt=$(jq 'length' "$f" 2>/dev/null)
      first=$(jq -r '[.[] | select(.role == "user")][0].content // ""' "$f" 2>/dev/null | head -n 1 | cut -c 1-60)
      mark=""
      [ "$id" = "$CONVO_ID" ] && mark=" (active)"
      INT_OUT="$INT_OUT$id | $cnt msgs | $first$mark
"
    done
    [ "$found" -eq 1 ] || INT_OUT="No saved conversations."
    ;;
  show)
    valid_id "$arg" || {
      INT_OUT="Invalid conversation id."
      return 0
    }
    f="$CONVO_DIR/$arg.json"
    if [ ! -f "$f" ]; then
      INT_OUT="No such conversation: $arg"
      return 0
    fi
    msg_dim "Model: reading conversation $arg"
    INT_OUT=$(jq -r '.[] | "\(.role | ascii_upcase): \(.content)"' "$f" 2>/dev/null | cap_text 12000)
    ;;
  delete)
    valid_id "$arg" || {
      INT_OUT="Invalid conversation id."
      return 0
    }
    f="$CONVO_DIR/$arg.json"
    if [ "$arg" = "$CONVO_ID" ]; then
      INT_OUT="Refused: cannot delete the active conversation."
      return 0
    fi
    if [ ! -f "$f" ]; then
      INT_OUT="No such conversation: $arg"
      return 0
    fi
    if approve "Model wants to delete conversation $arg. Allow?" force; then
      if rm -f "$f"; then INT_OUT="Deleted conversation $arg."; else INT_OUT="Failed to delete $arg."; fi
    else
      INT_OUT="The user declined the deletion."
    fi
    ;;
  *)
    INT_OUT="Unknown internal command. Use: list, show <id>, delete <id>."
    ;;
  esac
  INT_OUT=$(printf '%s' "$INT_OUT")
  printf '%s\n' "$INT_OUT" | gutter
}

# =========================================================================
# One turn: user input -> model -> (command -> output -> model)* -> answer
# =========================================================================
strip_prefix() {
  printf '%s\n' "$1" | sed -e '1s/^[^:]*:[[:space:]]*//' -e '/./,$!d'
}

run_turn() { # user text
  printf '\n'
  hist_add user "$1" || {
    msg_err "Could not write to history."
    return 1
  }
  step=1
  while [ "$step" -le "$STEPS_LIMIT" ]; do
    [ "$step" -gt 1 ] && msg_dim "Step $step/$STEPS_LIMIT"
    call_model || return 1
    hist_add assistant "$REPLY"

    case "$REPLY" in
    [Aa][Nn][Ss][Ww][Ee][Rr]:*)
      show_reply "$(strip_prefix "$REPLY")"
      return 0
      ;;
    [Ii][Nn][Tt][Ee][Rr][Nn][Aa][Ll]:*)
      if [ "$MODE" != "convo" ]; then
        msg_warn "Internal commands only work in conversation mode (--chat)."
        return 1
      fi
      internal_cmd "$(strip_prefix "$REPLY")"
      feedback="INTERNAL RESULT:
$INT_OUT"
      ;;
    *)
      show_cmd "$REPLY"
      first=${REPLY%%[[:space:]]*}
      force=""
      if [ "$AUTO" = "true" ] && ! command -v "$first" >/dev/null 2>&1; then
        force="force"
        msg_warn "That does not look like a real command, so I am asking first."
      fi
      if ! approve "Run it?" "$force"; then
        if [ "$MODE" = "convo" ]; then
          hist_add user "The user declined to run that command."
        fi
        msg "Skipped."
        return 0
      fi
      run_cmd "$REPLY"
      if [ "$MODE" != "convo" ]; then return "$CMD_RC"; fi
      feedback="COMMAND OUTPUT (exit status $CMD_RC):
$CMD_OUT
Continue with the next command, or reply with ANSWER: if you are done."
      ;;
    esac
    hist_add user "$feedback"
    step=$((step + 1))
  done
  msg_warn "Reached the step limit ($STEPS_LIMIT). Send another message to continue."
  return 1
}

# =========================================================================
# Conversation mode
# =========================================================================
start_convo() {
  if [ "$TEMP_SESSION" = "true" ]; then
    CONVO_ID="temp"
    HIST="$TMP_DIR/hist.json"
  else
    (
      umask 077
      mkdir -p "$CONVO_DIR"
    ) || die "Cannot create $CONVO_DIR."
    CONVO_ID=$(date +%Y%m%d-%H%M%S)
    [ -e "$CONVO_DIR/$CONVO_ID.json" ] && CONVO_ID="$CONVO_ID-$$"
    HIST="$CONVO_DIR/$CONVO_ID.json"
  fi
}

chat_info() {
  if [ "$TEMP_SESSION" = "true" ]; then sess="temporary (nothing is saved)"; else sess="$CONVO_ID (saved)"; fi
  if [ "$AUTO" = "true" ]; then appr="automatic (yolo)"; else appr="ask before running commands"; fi
  msg "Provider: $(provider_label "$PROVIDER")  |  Model: $MODEL"
  msg "Session:  $sess  |  Approval: $appr"
  msg_dim "/exit leave (kept)  |  /delete leave and delete this chat  |  /help"
}

convo_loop() {
  DELETED="false"
  MODE="convo"
  start_convo
  build_prompt
  chat_info

  if [ -n "$QUERY" ]; then
    printf '%syou>%s %s\n' "$C_USER" "$C_RESET" "$QUERY"
    run_turn "$QUERY"
  fi
  while :; do
    printf '\n%syou>%s ' "$C_USER" "$C_RESET"
    IFS= read -r line || {
      printf '\n'
      break
    }
    line=$(trim "$line")
    case "$line" in
    '') continue ;;
    /exit | /quit | exit | quit) break ;;
    /help)
      chat_help
      continue
      ;;
    /delete)
      if [ "$TEMP_SESSION" = "true" ] || [ ! -f "$HIST" ]; then
        msg "Nothing is saved for this chat."
        break
      fi
      if approve "Delete this chat ($CONVO_ID) and exit?"; then
        rm -f "$HIST"
        DELETED="true"
        break
      fi
      msg "Kept."
      continue
      ;;
    esac
    run_turn "$line"
  done
  printf '\n'
  if [ "$DELETED" = "true" ]; then
    msg "Bye. Chat deleted: $CONVO_ID"
  elif [ "$TEMP_SESSION" = "true" ]; then
    msg "Bye. Temporary session discarded."
  elif [ -f "$HIST" ]; then
    msg "Bye. Conversation saved: $CONVO_ID"
  else
    msg "Bye."
  fi
}

# =========================================================================
# Main
# =========================================================================
if [ "$CONVO" = "true" ]; then
  convo_loop
  exit 0
fi

if [ -z "$QUERY" ]; then
  msg_err "No request given."
  msg_err 'Try: ai.sh "your request"   or   ai.sh --chat   (see --help)'
  exit 1
fi

MODE="oneshot"
STEPS_LIMIT=1
HIST="$TMP_DIR/hist.json"
build_prompt
run_turn "$QUERY"
exit $?
