#!/bin/bash
# Installs powerbar (login agent, this user) and pbd (root LaunchDaemon, applies Low Power Mode / lid setting).
# Run in Terminal: bash install.sh   (asks for the admin password once, for pbd)
set -e
cd "$(dirname "$0")"
# build from source (needs the Xcode command line tools: xcode-select --install)
if [ ! -x powerbar ] || [ powerbar.swift -nt powerbar ]; then
  swiftc -O -o powerbar powerbar.swift
  codesign -s - -f powerbar
fi
mkdir -p ~/.local/bin ~/Library/LaunchAgents /Users/Shared/powerbar
chmod 755 /Users/Shared/powerbar          # only this user writes the choices the root service reads
install -m 755 powerbar ~/.local/bin/powerbar
sed "s#__HOME__#$HOME#" local.powerbar.plist > ~/Library/LaunchAgents/local.powerbar.plist
launchctl bootout gui/$(id -u)/local.powerbar 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.powerbar.plist
sudo install -d -m 755 -o root -g wheel /usr/local/libexec
sudo install -m 755 -o root -g wheel pbd.sh /usr/local/libexec/pbd.sh
sudo install -m 644 -o root -g wheel local.pbd.plist /Library/LaunchDaemons/local.pbd.plist
sudo launchctl bootout system/local.pbd 2>/dev/null || true
sudo launchctl bootstrap system /Library/LaunchDaemons/local.pbd.plist
sleep 2
launchctl print gui/$(id -u)/local.powerbar | grep -E "state =|pid =" || true
sudo launchctl print system/local.pbd | grep -E "state =|pid =" || true
echo "installed"
