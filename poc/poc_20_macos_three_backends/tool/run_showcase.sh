#!/usr/bin/env bash
# Builds the three macOS backends and opens them side by side, left to right:
#
#   1 SkyLight/CGS           blue    pure Dart, private API, no window frame
#   2 AppKit signal hijack   green   pure Dart, thread 0 taken over by SIGUSR2
#   3 AppKit native host     orange  Objective-C main(), frame sent from Dart
#
# Each window paints its own number, name and pid into the frame, so they can
# be told apart even where there is no title bar.
#
#   tool/run_showcase.sh            hold until closed (Ctrl+C stops all three)
#   tool/run_showcase.sh 30         close everything after 30 seconds
set -euo pipefail

package="$(cd "$(dirname "$0")/.." && pwd)"
out="$package/build/showcase"
seconds="${1:-0}"
mkdir -p "$out"

echo "building into $out"
clang -fobjc-arc -Wall -Wextra \
  -framework Cocoa -framework QuartzCore -framework IOSurface \
  "$package/native/minimal_appkit_host.m" -o "$out/backend3_native_host"
dart compile exe "$package/bin/showcase.dart" -o "$out/showcase" >/dev/null
dart compile exe "$package/../poc_03_appkit_window/bin/probe.dart" \
  -o "$out/backend2_appkit_signal" >/dev/null
# Same program as `showcase`, under the name the WindowServer will list as the
# owner of backend 1's window.
cp "$out/showcase" "$out/backend1_skylight"

"$out/backend1_skylight" skylight "$seconds" &
"$out/backend2_appkit_signal" showcase-signal "$seconds" &
"$out/showcase" appkit-native-host "$out/backend3_native_host" "$seconds" &

echo "three backends running; Ctrl+C closes them all"
trap 'kill $(jobs -p) 2>/dev/null || true' INT TERM
wait
