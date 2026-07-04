#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/madaboutcode/manbok.git"
INSTALL_DIR="$HOME/.local/bin"
LAUNCH_AGENT_LABEL="com.manbok.app"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
GUI_DOMAIN="gui/$(id -u)"

info()  { printf '==> %s\n' "$1"; }
ok()    { printf '[ok] %s\n' "$1"; }
err()   { printf '[error] %s\n' "$1" >&2; }
die()   { err "$1"; exit 1; }

cleanup() {
  if [ -n "${TMPDIR_CREATED:-}" ] && [ -d "$TMPDIR_CREATED" ]; then
    rm -rf "$TMPDIR_CREATED"
  fi
}

info "manbok installer"
echo ""

# --- preflight ---

if [ "$(uname -s)" != "Darwin" ]; then
  die "manbok requires macOS. This system is $(uname -s)."
fi

if ! xcode-select -p >/dev/null 2>&1; then
  die "Xcode Command Line Tools not found. Install them first:
    xcode-select --install
Then re-run this script."
fi

if ! command -v swift >/dev/null 2>&1; then
  die "swift not found. Install Xcode Command Line Tools:
    xcode-select --install"
fi

if ! command -v git >/dev/null 2>&1; then
  die "git not found. Install Xcode Command Line Tools:
    xcode-select --install"
fi

ok "preflight checks passed"

# --- clone ---

TMPDIR_CREATED="$(mktemp -d)"
trap cleanup EXIT

info "cloning manbok..."
if ! git clone --depth 1 "$REPO_URL" "$TMPDIR_CREATED/manbok" 2>&1; then
  die "git clone failed. Check your internet connection and try again."
fi
ok "cloned"

# --- build ---

info "building release binary (this may take a minute)..."
cd "$TMPDIR_CREATED/manbok"
if ! swift build -c release 2>&1; then
  err "build failed. Source left at: $TMPDIR_CREATED/manbok"
  TMPDIR_CREATED=""  # prevent cleanup so user can inspect
  exit 1
fi
ok "built .build/release/manbok"

# --- install binary ---

info "installing to $INSTALL_DIR/manbok..."

mkdir -p "$INSTALL_DIR"

# stop existing daemon if running
if [ -x "$INSTALL_DIR/manbok" ]; then
  "$INSTALL_DIR/manbok" stop 2>/dev/null || true
  sleep 0.3
fi

install -m 755 .build/release/manbok "$INSTALL_DIR/manbok"
ok "binary installed"

# --- authorize mic ---

info "requesting microphone authorization..."
"$INSTALL_DIR/manbok" authorize 2>/dev/null || true
ok "authorize requested (approve the system prompt when it appears)"

# --- LaunchAgent ---

info "setting up LaunchAgent for login persistence..."

mkdir -p "$HOME/Library/LaunchAgents"

# unload existing agent if present
launchctl bootout "$GUI_DOMAIN" "$LAUNCH_AGENT_PLIST" 2>/dev/null || true

sed -e "s|REPLACE_WITH_MANBOK_PATH|${INSTALL_DIR}/manbok|g" \
    -e "s|REPLACE_WITH_HOME|${HOME}|g" \
    resources/com.manbok.app.plist > "$LAUNCH_AGENT_PLIST"

launchctl bootstrap "$GUI_DOMAIN" "$LAUNCH_AGENT_PLIST"
ok "LaunchAgent loaded"

sleep 1
"$INSTALL_DIR/manbok" status 2>/dev/null || true

# --- PATH check ---

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    echo ""
    info "add to your PATH (once):"
    echo ""
    echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
    echo "  source ~/.zshrc"
    echo ""
    ;;
esac

# --- done ---

echo ""
echo "--------------------------------------------"
echo "  manbok installed"
echo "--------------------------------------------"
echo ""
echo "  binary:      $INSTALL_DIR/manbok"
echo "  LaunchAgent: $LAUNCH_AGENT_PLIST"
echo "  logs:        /tmp/manbok.stderr.log"
echo "               Console.app -> subsystem: ai.manbok.app"
echo ""
echo "  The daemon starts automatically at login."
echo "  Approve the microphone prompt when it appears."
echo ""
echo "  Quick start:"
echo "    manbok status          # check daemon state"
echo "    manbok dump            # export latest recording"
echo "    manbok dump --list     # list sessions"
echo "    manbok stop            # stop daemon"
echo ""
echo "  Uninstall:"
echo "    launchctl bootout $GUI_DOMAIN $LAUNCH_AGENT_PLIST"
echo "    rm -f $LAUNCH_AGENT_PLIST $INSTALL_DIR/manbok"
echo ""
