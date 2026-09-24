#!/bin/sh
# Installs stayawake from this checkout. Asks for your password once, for the
# helper only: everything the app and the CLI do afterwards needs no password.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
UID_NUM=$(id -u)
APP="$HOME/Applications/StayAwake.app"
AGENT="$HOME/Library/LaunchAgents/com.macstayawake.app.plist"
DAEMON_PLIST=/Library/LaunchDaemons/com.macstayawake.helper.plist

# launchctl bootout returns before the service has finished going away, and
# bootstrapping into that gap fails with "Input/output error". Wait it out.
wait_gone() {
  i=0
  while launchctl print "$1" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -gt 50 ] && return 1
    sleep 0.1
  done
  return 0
}

# --- requirements, checked before anything is installed -------------------

MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MACOS_MAJOR" -lt 14 ]; then
  echo "error: this needs macOS 14 or newer (found $(sw_vers -productVersion))." >&2
  echo "       The menu bar app uses MenuBarExtra, which older systems do not have." >&2
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found, so the menu bar app cannot be built." >&2
  echo "       Install the command line tools and run this again:" >&2
  echo "           xcode-select --install" >&2
  exit 1
fi

# --- the parts that need no password --------------------------------------

"$HERE/app/build.sh"

mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__APP__|$APP|" "$HERE/app/com.macstayawake.app.plist.template" > "$AGENT"
launchctl bootout "gui/$UID_NUM/com.macstayawake.app" 2>/dev/null || true
wait_gone "gui/$UID_NUM/com.macstayawake.app" || true
launchctl bootstrap "gui/$UID_NUM" "$AGENT"

# --- the helper, which runs as root ---------------------------------------
#
# It is installed into /usr/local/sbin rather than run from this checkout:
# a root process must not execute a file that an ordinary user can rewrite.
#
# The files are staged through a temp directory first. macOS protects
# ~/Documents, ~/Desktop and ~/Downloads with TCC, and a privileged process
# without Full Disk Access cannot read a checkout that lives in one of them,
# whatever the file permissions say.

STAGE=$(mktemp -d /tmp/stayawake-install.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT INT TERM
cp "$HERE/helper/stayawaked" "$HERE/bin/stayawake" \
   "$HERE/helper/com.macstayawake.helper.plist" "$STAGE/"

PRIV="mkdir -p /usr/local/sbin /usr/local/bin && \
install -o root -g wheel -m 755 '$STAGE/stayawaked' /usr/local/sbin/stayawaked && \
install -o root -g wheel -m 755 '$STAGE/stayawake' /usr/local/bin/stayawake && \
install -o root -g wheel -m 644 '$STAGE/com.macstayawake.helper.plist' '$DAEMON_PLIST' && \
{ launchctl bootout system/com.macstayawake.helper 2>/dev/null || true; } && \
{ for i in 1 2 3 4 5 6 7 8 9 10; do launchctl print system/com.macstayawake.helper >/dev/null 2>&1 || break; sleep 0.5; done; } && \
launchctl bootstrap system '$DAEMON_PLIST' && \
launchctl enable system/com.macstayawake.helper"

if [ -t 0 ] && [ -t 1 ]; then
  sudo sh -c "$PRIV"
else
  # No controlling terminal, so sudo cannot prompt. Raise the macOS auth dialog
  # instead, with text that says what is being installed: the dialog names the
  # process that asked (osascript), which on its own explains nothing.
  osascript -e "do shell script \"$PRIV\" with prompt \"Stay Awake needs permission to install its background helper, which is what allows the Mac to stay awake with the lid closed.\" with administrator privileges" >/dev/null
fi

echo
echo "installed."
echo "  menu bar: look for the Stay Awake icon"
echo "  terminal: stayawake"
