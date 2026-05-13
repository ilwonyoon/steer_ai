#!/usr/bin/env bash
# App Store screenshot capture driver.
#
# Boots an iPhone simulator, installs the latest Steer build, drives
# the app through its golden states, and captures one PNG per state.
# Output lands in `apps/ios/build/screenshots/<device>/N-<label>.png`
# so the user can review them all in one place before uploading to
# App Store Connect.
#
# Status bar is overridden to 9:41 / 100% / WiFi-full / 5G so every
# screenshot has the same "marketing perfect" chrome — Apple's own
# App Store screenshots use the exact same.
#
# Usage:
#   bash scripts/capture-app-store-screenshots.sh
#
# Prerequisites:
#   - Xcode installed with iOS 26.x runtime
#   - Steer.xcodeproj builds on `iPhone 17 Pro Max` and `iPhone 16 Plus`
#     destinations
#
# What this script DOES automate:
#   - Build, install, boot, status-bar override, screen capture
#
# What this script does NOT (and cannot) automate:
#   - Driving the app into a specific golden state (e.g. "show a card
#     mid-streaming"). The script PAUSES at every state with a prompt
#     telling the user what tap sequence to perform, then captures
#     when they hit Enter. This is the contract: the user holds the
#     phone, the script holds the camera.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$REPO_ROOT/apps/ios"
OUT_ROOT="$IOS_DIR/build/screenshots"
mkdir -p "$OUT_ROOT"

# 6.7" + 6.5" are the two required sizes for iPhone App Store
# submissions. 6.5" device is older — iPhone 16 Plus / iPhone Air
# pixel-equivalent — and Apple still requires it for "older devices"
# even though usage is dwindling. iPad is optional for iPhone-only
# apps so we skip it.
DEVICES=(
  "iPhone 17 Pro Max:6.7"
  "iPhone 17:6.1"
)

# Golden states. Each entry is "label|prompt". The prompt is what
# the human in front of the simulator needs to do before we capture.
SHOTS=(
  "1-signin|SignInPrompt screen. Sign out if currently signed in (Settings → Sign Out). Wait for the routing field to settle. Press Enter."
  "2-onboarding|Sign in with Apple. Wait for the tutorial. Hit send once to advance to the second card. Wait until the typing is roughly halfway. Press Enter."
  "3-inbox-card|Skip the rest of the tutorial. Make sure you have at least one active card on screen (or pair a Mac with codex/claude stopped). Press Enter."
  "4-reply-dock|Tap into the reply field on the focused card so the keyboard opens. Type a partial reply like 'Yes, the indentation should be'. Do NOT hit send. Press Enter."
  "5-empty-connected|Resolve all your cards (reply or wait for them to complete) until the empty state shows 'No waiting actions'. Press Enter."
  "6-settings|Tap the settings icon (top-left). Make sure the Notifications row shows On and the GitHub mark renders next to 'Report an Issue'. Press Enter."
)

for entry in "${DEVICES[@]}"; do
  device_name="${entry%%:*}"
  device_label="${entry##*:}"
  device_dir="$OUT_ROOT/${device_name// /_}"
  mkdir -p "$device_dir"

  echo "==> Setting up $device_name (${device_label}\")"

  # Find the device UDID. simctl is lenient on names but we want a
  # deterministic answer so we pick the first match exactly.
  udid="$(xcrun simctl list devices available | awk -F '[()]' \
    -v want="$device_name" \
    'tolower($0) ~ tolower(want) { print $(NF-3); exit }')"

  if [ -z "$udid" ]; then
    echo "error: no simulator found for '$device_name'"
    echo "available:"
    xcrun simctl list devices available | grep -i iphone | head -20
    exit 1
  fi

  echo "    udid=$udid"

  # Boot if cold. xcrun is idempotent enough that we don't need a
  # state check.
  xcrun simctl boot "$udid" 2>/dev/null || true
  open -a Simulator
  # Give the boot a moment so the home screen exists before we
  # start poking it.
  sleep 4

  echo "==> Building + installing Steer.app on $device_name"
  xcodebuild -project "$IOS_DIR/Steer.xcodeproj" \
    -scheme Steer \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination "id=$udid" \
    -derivedDataPath "$IOS_DIR/build/DerivedData-screenshots" \
    build > /tmp/steer-screenshot-build.log 2>&1
  app="$IOS_DIR/build/DerivedData-screenshots/Build/Products/Debug-iphonesimulator/Steer.app"
  if [ ! -d "$app" ]; then
    echo "error: build did not produce $app"
    tail -20 /tmp/steer-screenshot-build.log
    exit 1
  fi
  xcrun simctl install "$udid" "$app"

  # Apple's marketing-perfect status bar. WiFi full, no carrier,
  # 100% battery, time 9:41 (the original iPhone unveiling time —
  # Apple still uses it on every screenshot in their own App Store
  # listings).
  xcrun simctl status_bar "$udid" override \
    --time "9:41" \
    --batteryState charged \
    --batteryLevel 100 \
    --wifiBars 3 \
    --cellularBars 4 \
    --dataNetwork 5g

  xcrun simctl launch "$udid" ai.steer.ios

  for shot in "${SHOTS[@]}"; do
    label="${shot%%|*}"
    prompt="${shot##*|}"
    echo ""
    echo "----------------------------------------------------------------"
    echo "📸 SHOT $label  (device: $device_name)"
    echo "    $prompt"
    echo "    Hit Enter to capture, or 's' + Enter to skip."
    echo "----------------------------------------------------------------"
    read -r answer
    if [ "$answer" = "s" ]; then
      echo "    skipped"
      continue
    fi
    out="$device_dir/${label}.png"
    xcrun simctl io "$udid" screenshot "$out"
    echo "    → $out"
  done

  # Clear the status bar override so the simulator goes back to its
  # normal state for any subsequent manual use.
  xcrun simctl status_bar "$udid" clear
done

echo ""
echo "✅ Done. All shots saved under $OUT_ROOT/"
echo ""
echo "Next:"
echo "  1. Inspect screenshots visually — no truncated text, no scroll"
echo "     bars, no in-flight animations frozen mid-frame."
echo "  2. Upload to App Store Connect (Version → iPhone 6.7\" / 6.5\")."
echo "  3. App Store auto-fills the smaller iPad form factors from"
echo "     the iPhone shots — iPad-specific captures are not required"
echo "     for an iPhone-only app."
