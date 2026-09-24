#!/bin/sh
# Removes everything and leaves sleep working the way macOS normally does.
set -e
UID_NUM=$(id -u)

launchctl bootout "gui/$UID_NUM/com.macstayawake.app" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.macstayawake.app.plist"
rm -rf "$HOME/Applications/StayAwake.app"

PRIV="{ launchctl bootout system/com.macstayawake.helper 2>/dev/null || true; } && \
rm -f /Library/LaunchDaemons/com.macstayawake.helper.plist /usr/local/sbin/stayawaked /usr/local/bin/stayawake && \
pmset -a disablesleep 0"

if [ -t 0 ] && [ -t 1 ]; then
  sudo sh -c "$PRIV"
else
  osascript -e "do shell script \"$PRIV\" with prompt \"Stay Awake needs permission to remove its background helper and restore normal sleep.\" with administrator privileges" >/dev/null
fi

rm -f "$HOME/.stayawake/state" "$HOME/.stayawake/lease" "$HOME/.stayawake/veto" \
      "$HOME/.stayawake/disabled" "$HOME/.stayawake/app-alive"

echo "removed. Sleep behaviour is back to the macOS default."
echo "Your settings are still in ~/.stayawake/config; delete that folder to remove them too."
