#!/bin/bash
# Seeds everything `maestro test ios/maestro` needs, in one go, on a fresh local Worker database.
# usage: B=http://127.0.0.1:8796 ./seed-all.sh <wrangler --persist-to dir> clip.m4a
set -euo pipefail
cd "$(dirname "$0")"; export B=${B:-http://127.0.0.1:8795}
./seed.sh "$2"                                   # 會議測試 (01–05, 12)
TITLE=管理測試 SUMMARY=1 ./seed.sh "$2"          # 07–09
TITLE=知識測試 KNOWLEDGE=1 ./seed.sh "$2"        # 10–11
PARITY=1 STATE="$1" ./seed.sh "$2"              # 12; last, since it marks the runner offline
