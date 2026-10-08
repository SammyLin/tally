#!/bin/bash
# Puts an audio file into the booted simulator's Files app (我的 iPhone) as 「分享測試.<ext>」 for flow 13.
# usage: ./seed-files.sh clip.mp3 [simulator udid, default booted]
set -euo pipefail
G=$(xcrun simctl get_app_container "${2:-booted}" com.apple.DocumentsApp groups | awk -F'\t' '/FileProvider.LocalStorage/{print $2}')
mkdir -p "$G/File Provider Storage"
cp "$1" "$G/File Provider Storage/分享測試.${1##*.}"
