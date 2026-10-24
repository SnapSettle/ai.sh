#!/bin/sh
# install.sh - installer for ai.sh (works from bash, zsh, fish, dash, ... because it is run by sh)
#
#   curl -fsSL https://raw.githubusercontent.com/snapsettle/ai.sh/main/install.sh | sh
#
# Options (after "sh -s --"):   --uninstall   remove ai.sh      --help   show this text
# Environment variables:
#   AI_SH_INSTALL_DIR  where to install (default: ~/.local/bin)
#   AI_SH_VERSION      install a specific release, e.g. 2026.10.25 (default: latest)

REPO="snapsettle/ai.sh"
BASE="${AI_SH_BASE_URL:-https://github.com/$REPO/releases}"
DIR="${AI_SH_INSTALL_DIR:-$HOME/.local/bin}"
WANT="${AI_SH_VERSION:-latest}"

TMP=""
cleanup() { [ -z "$TMP" ] || rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

say() { printf '[install] %s\n' "$*"; }
fail() {
  printf '[install] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '2,10p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
  exit 0
}

fetch() { # url outfile
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 60 "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    fail "Neither curl nor wget was found. Please install one of them."
  fi
}

sha256_of() {
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

uninstall() {
  removed=0
  if [ -f "$DIR/ai.sh" ]; then
    rm -f "$DIR/ai.sh" && removed=1
  fi
  if [ -L "$DIR/ai" ] && [ "$(readlink "$DIR/ai")" = "ai.sh" ]; then
    rm -f "$DIR/ai"
  fi
  if [ "$removed" -eq 1 ]; then say "Removed ai.sh from $DIR"; else say "Nothing to remove in $DIR"; fi
  say "Your settings and saved chats were kept. To delete them too, run 'ai.sh --reset' BEFORE uninstalling."
  exit 0
}

case "${1:-}" in
--uninstall) uninstall ;;
-h | --help) usage ;;
esac

# --- build the download address -----------------------------------------
case "$WANT" in
latest) URL="$BASE/latest/download" ;;
v*) URL="$BASE/download/$WANT" ;;
*) URL="$BASE/download/v$WANT" ;;
esac

TMP=$(mktemp -d 2>/dev/null) || fail "Cannot create a temporary folder."

say "Downloading ai.sh ($WANT)..."
fetch "$URL/ai.sh" "$TMP/ai.sh" || fail "Download failed. Is the version right, and are you online?"
fetch "$URL/ai.sh.sha256" "$TMP/ai.sh.sha256" || fail "Could not download the checksum file."

# --- verify -----------------------------------------------------------------
want_sum=$(awk '{ print $1; exit }' "$TMP/ai.sh.sha256")
got_sum=$(sha256_of "$TMP/ai.sh") || fail "Need sha256sum, shasum or openssl to verify the download."
[ -n "$want_sum" ] && [ "$want_sum" = "$got_sum" ] || fail "Checksum mismatch. Nothing was installed."
sh -n "$TMP/ai.sh" 2>/dev/null || fail "The downloaded file is not a valid script. Nothing was installed."

# --- install ----------------------------------------------------------------
mkdir -p "$DIR" || fail "Cannot create $DIR (try AI_SH_INSTALL_DIR=/some/folder you own)."
cp "$TMP/ai.sh" "$DIR/ai.sh.new" || fail "Cannot write to $DIR."
chmod 755 "$DIR/ai.sh.new"
mv "$DIR/ai.sh.new" "$DIR/ai.sh" || fail "Cannot write to $DIR."

# Short alias "ai", but never overwrite something that is not ours.
if [ ! -e "$DIR/ai" ] || { [ -L "$DIR/ai" ] && [ "$(readlink "$DIR/ai")" = "ai.sh" ]; }; then
  ln -sf ai.sh "$DIR/ai"
  ALIAS="ai"
else
  ALIAS=""
  say "Note: $DIR/ai already exists and is not ours, so the short name 'ai' was not created."
fi

installed=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$DIR/ai.sh" | head -n 1)
say "Installed ai.sh $installed to $DIR"

# --- friendly checks --------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  say "WARNING: 'jq' is required but not installed. Install it with your package manager (apt, dnf, pacman, brew, ...)."
fi
if [ -e /etc/NIXOS ]; then
  say "Tip: you are on NixOS. The Nix package is nicer (see the README) because Nix keeps it updated for you."
fi

case ":$PATH:" in
*":$DIR:"*) ;;
*)
  say "$DIR is not in your PATH yet. Add it for your shell, then open a new terminal:"
  case "$(basename "${SHELL:-sh}")" in
  fish) say "  fish_add_path $DIR" ;;
  zsh) say "  echo 'export PATH=\"$DIR:\$PATH\"' >> ~/.zshrc" ;;
  bash) say "  echo 'export PATH=\"$DIR:\$PATH\"' >> ~/.bashrc" ;;
  *) say "  echo 'export PATH=\"$DIR:\$PATH\"' >> ~/.profile" ;;
  esac
  ;;
esac

say "Done. Start with: ai.sh --help   (first run walks you through setup)"
[ -z "$ALIAS" ] || say "You can also type just: ai"
say "Update later with: ai.sh --update"
