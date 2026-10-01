#!/bin/sh
# Installs (or reinstalls) this runner as a launchd agent for the current user, using this directory.
# Run after building ./tally (see docs/SETUP.md). Also removes the pre-rename ai.3mi.noteapp-runner agent.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
label=ai.3mi.tally-runner
agents="$HOME/Library/LaunchAgents"
plist="$agents/$label.plist"
dom="gui/$(id -u)"

[ -x "$dir/tally" ] || { echo "build ./tally first (docs/SETUP.md step 3)" >&2; exit 1; }
[ -f "$dir/.env" ] || { echo "missing $dir/.env (copy .env.example)" >&2; exit 1; }

launchctl bootout "$dom/ai.3mi.noteapp-runner" 2>/dev/null || true
rm -f "$agents/ai.3mi.noteapp-runner.plist"
launchctl bootout "$dom/$label" 2>/dev/null || true

mkdir -p "$agents" "$dir/data/logs"
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$dir/tally</string>
    <string>run</string>
  </array>
  <key>WorkingDirectory</key><string>$dir</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ExitTimeOut</key><integer>30</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$dir/data/logs/runner.log</string>
  <key>StandardErrorPath</key><string>$dir/data/logs/runner.log</string>
</dict>
</plist>
EOF
plutil -lint "$plist" >/dev/null
launchctl enable "$dom/$label"
launchctl bootstrap "$dom" "$plist"
echo "started $label — log: $dir/data/logs/runner.log"
