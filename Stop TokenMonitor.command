#!/usr/bin/env bash
osascript -e 'tell application "TokenMonitor" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application "Token Monitor" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application "System Events" to tell process "TokenMonitor" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application "System Events" to tell process "Token Monitor" to quit' >/dev/null 2>&1 || true
killall TokenMonitor >/dev/null 2>&1 || true
killall "Token Monitor" >/dev/null 2>&1 || true
killall -9 TokenMonitor >/dev/null 2>&1 || true
killall -9 "Token Monitor" >/dev/null 2>&1 || true
pkill -9 -f "TokenMonitor.app" >/dev/null 2>&1 || true
echo "TokenMonitor stopped. You can close this window."
