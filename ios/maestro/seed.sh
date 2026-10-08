#!/bin/bash
# Seeds a local Worker (DEV_NO_AUTH=1) for the flows: uploads $1 as 「會議測試」 via the multipart API, then plays
# runner for every queued recording (source as play file + a canned 3-segment transcript). Run again to process
# recordings uploaded by the app.  usage: B=http://127.0.0.1:8795 ./seed.sh [clip.m4a]
set -euo pipefail
B=${B:-http://127.0.0.1:8795}; H='Content-Type: application/json'; R=maestro; tmp=$(mktemp -d)
j() { python3 -c "import sys,json;print(eval(sys.argv[1],{'d':json.load(sys.stdin)}))" "$1"; }
if [ -n "${1:-}" ]; then
  rid=$(curl -sf -m 10 $B/api/uploads -H "$H" -d "{\"filename\":\"會議測試.m4a\",\"size\":$(stat -f%z "$1")}" | j 'd["recording_id"]')
  et=$(curl -sf -m 60 -X PUT --data-binary @"$1" $B/api/uploads/$rid/1 | j 'd["etag"]')
  curl -sf -m 10 $B/api/uploads/$rid/complete -H "$H" -d "{\"parts\":[{\"part\":1,\"etag\":\"$et\"}]}" >/dev/null
fi
for _ in $(seq 1 20); do
  id=$(curl -sf -m 10 $B/api/runner/claim -H "$H" -d "{\"runner\":\"$R\"}" | j '(d["job"] or {}).get("id","") if (d["job"] or {}).get("kind")=="recording" else ""')
  [ -z "$id" ] && break
  curl -sf -m 30 -o $tmp/src $B/api/runner/recordings/$id/source
  ms=$(afinfo $tmp/src | awk '/estimated duration/{printf "%d", $3*1000}')
  curl -sf -m 30 -X PUT --data-binary @$tmp/src -H 'Content-Type: audio/mp4' "$B/api/runner/recordings/$id/play?runner=$R" >/dev/null
  a=$((ms/3)); b=$((2*ms/3))
  curl -sf -m 10 $B/api/runner/recordings/$id/transcript -H "$H" -d "{\"runner\":\"$R\",\"duration_s\":$((ms/1000)).$((ms%1000)),\"speakers\":[{\"label\":\"SPEAKER_00\",\"display_name\":\"說話者 1\"},{\"label\":\"SPEAKER_01\",\"display_name\":\"說話者 2\"}],\"segments\":[{\"start_ms\":0,\"end_ms\":$a,\"speaker\":0,\"text_raw\":\"大家好，今天我們來討論新的 iOS app。\"},{\"start_ms\":$a,\"end_ms\":$b,\"speaker\":1,\"text_raw\":\"第一點是錄音功能，第二點是上傳佇列。\"},{\"start_ms\":$b,\"end_ms\":$ms,\"speaker\":0,\"text_raw\":\"第三點是逐字稿與講者命名。謝謝大家。\"}]}" >/dev/null
  curl -sf -m 10 $B/api/runner/recordings/$id/done -H "$H" -d "{\"runner\":\"$R\"}" >/dev/null
  echo "processed #$id"
done
rm -rf $tmp
