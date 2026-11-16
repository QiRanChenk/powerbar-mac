#!/bin/bash
launchctl bootout gui/$(id -u)/local.powerbar 2>/dev/null || true
rm -f ~/Library/LaunchAgents/local.powerbar.plist ~/.local/bin/powerbar
sudo launchctl bootout system/local.pbd 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/local.pbd.plist /usr/local/libexec/pbd.sh
sudo pmset -a disablesleep 0
echo "removed (Low Power Mode settings left as they are)"
