#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output_dir="$script_dir/build"
output="$output_dir/dart_ui_macos_host"
source_file="$script_dir/dart_ui_macos_host.m"

mkdir -p "$output_dir"
xcrun clang \
  -fobjc-arc \
  -Wall \
  -Wextra \
  -framework Cocoa \
  -framework IOSurface \
  -framework QuartzCore \
  "$source_file" \
  -o "$output"

printf '%s\n' "$output"
