#!/bin/bash
# Seeds a local Worker (DEV_NO_AUTH=1) for the flows: uploads $1 as 「會議測試」 via the multipart API, then plays
# runner for every queued recording (source as play file + a canned 3-segment transcript). Run again to process
# recordings uploaded by the app (and every queued summary, with a canned result).
# usage: B=http://127.0.0.1:8795 [TITLE=會議測試] [SUMMARY=1] [KNOWLEDGE=1] ./seed.sh [clip.m4a]
#   TITLE: title of the uploaded clip; SUMMARY=1: also queue a 會議 summary for it (processed by the same loop)
#   KNOWLEDGE=1 (flows 10–11; use TITLE=知識測試 + clip so 「會議測試」 keeps 說話者 1/2 for 03–05): people 王小明 / 陳大華 (the TITLE recording's two speakers), a vocabulary
#   suggestion 「iOS」, and two asks: one answered with citations into TITLE, one failed
#   PARITY=1 STATE=<wrangler --persist-to dir> [clip.m4a] (flow 12; the clip is not uploaded as 「會議測試」 then, after 「會議測試」 is processed): a 會議 summary with a
#   Markdown table / numbered list / quote / code on 「會議測試」, the clip uploaded as 「排隊測試」 and left queued, and
#   every runner marked as last seen an hour ago (offline) in the local D1 database
set -euo pipefail
B=${B:-http://127.0.0.1:8795}; TITLE=${TITLE:-會議測試}; H='Content-Type: application/json'; R=maestro; tmp=$(mktemp -d)
j() { python3 -c "import sys,json;print(eval(sys.argv[1],{'d':json.load(sys.stdin)}))" "$1"; }
if [ -n "${1:-}" ] && [ "${PARITY:-}" != 1 ]; then
  rid=$(curl -sf -m 10 $B/api/uploads -H "$H" -d "{\"filename\":\"$TITLE.m4a\",\"size\":$(stat -f%z "$1")}" | j 'd["recording_id"]')
  et=$(curl -sf -m 60 -X PUT --data-binary @"$1" $B/api/uploads/$rid/1 | j 'd["etag"]')
  curl -sf -m 10 $B/api/uploads/$rid/complete -H "$H" -d "{\"parts\":[{\"part\":1,\"etag\":\"$et\"}]}" >/dev/null
  echo "uploaded #$rid $TITLE"
fi
for _ in $(seq 1 20); do
  job=$(curl -sf -m 10 $B/api/runner/claim -H "$H" -d "{\"runner\":\"$R\"}" | j '"%s %s" % ((d["job"] or {}).get("kind",""), (d["job"] or {}).get("id",""))')
  kind=${job% *}; id=${job#* }
  [ -z "$kind" ] && break
  if [ "$kind" = summary ]; then
    curl -sf -m 10 $B/api/runner/summaries/$id/result -H "$H" -d "{\"runner\":\"$R\",\"content_md\":\"## 重點\\n- 錄音功能\\n- 上傳佇列\"}" >/dev/null
    echo "summary #$id"; continue
  fi
  curl -sf -m 30 -o $tmp/src $B/api/runner/recordings/$id/source
  ms=$(afinfo $tmp/src | awk '/estimated duration/{printf "%d", $3*1000}')
  curl -sf -m 30 -X PUT --data-binary @$tmp/src -H 'Content-Type: audio/mp4' "$B/api/runner/recordings/$id/play?runner=$R" >/dev/null
  a=$((ms/3)); b=$((2*ms/3))
  curl -sf -m 10 $B/api/runner/recordings/$id/transcript -H "$H" -d "{\"runner\":\"$R\",\"duration_s\":$(printf %d.%03d $((ms/1000)) $((ms%1000))),\"speakers\":[{\"label\":\"SPEAKER_00\",\"display_name\":\"說話者 1\"},{\"label\":\"SPEAKER_01\",\"display_name\":\"說話者 2\"}],\"segments\":[{\"start_ms\":0,\"end_ms\":$a,\"speaker\":0,\"text_raw\":\"大家好，今天我們來討論新的 iOS app。\"},{\"start_ms\":$a,\"end_ms\":$b,\"speaker\":1,\"text_raw\":\"第一點是錄音功能，第二點是上傳佇列。\"},{\"start_ms\":$b,\"end_ms\":$ms,\"speaker\":0,\"text_raw\":\"第三點是逐字稿與講者命名。謝謝大家。\"}]}" >/dev/null
  curl -sf -m 10 $B/api/runner/recordings/$id/done -H "$H" -d "{\"runner\":\"$R\"}" >/dev/null
  echo "processed #$id"
  if [ "${SUMMARY:-}" = 1 ] && [ "$id" = "${rid:-}" ]; then
    curl -sf -m 10 $B/api/recordings/$id/summaries -H "$H" -d '{"template_id":"meeting","language":"zh-TW"}' >/dev/null
  fi
done
rm -rf $tmp
if [ "${KNOWLEDGE:-}" = 1 ]; then
  rid=$(curl -sf -m 10 "$B/api/recordings?q=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$TITLE")" | j 'd[0]["id"]')
  segs=$(curl -sf -m 10 $B/api/recordings/$rid | j '" ".join(str(s["id"]) for s in d["segments"])'); set -- $segs
  curl -sf -m 10 $B/api/segments/$1/speaker -H "$H" -d '{"name":"王小明","scope":"all"}' >/dev/null
  curl -sf -m 10 $B/api/segments/$2/speaker -H "$H" -d '{"name":"陳大華","scope":"all"}' >/dev/null
  vid=$(curl -sf -m 10 $B/api/runner/claim -H "$H" -d "{\"runner\":\"$R\",\"vocab\":true}" | j '(d["job"] or {}).get("id","")')
  [ -n "$vid" ] && curl -sf -m 10 $B/api/runner/vocab/$vid/result -H "$H" \
    -d "{\"runner\":\"$R\",\"terms\":[{\"term\":\"iOS\",\"misheard\":[\"愛歐斯\"],\"kind\":\"product\"}]}" >/dev/null
  ask() { # $1 question; $2 answer JSON or "" to fail it
    local a; a=$(curl -sf -m 10 $B/api/asks -H "$H" -d "{\"question\":\"$1\"}" | j 'd["id"]')
    curl -sf -m 10 $B/api/runner/claim -H "$H" -d "{\"runner\":\"$R\",\"asks\":true}" >/dev/null
    if [ -n "$2" ]; then curl -sf -m 10 $B/api/runner/asks/$a/result -H "$H" -d "{\"runner\":\"$R\",$2}" >/dev/null
    else curl -sf -m 10 $B/api/runner/asks/$a/fail -H "$H" -d "{\"runner\":\"$R\",\"error\":\"測試失敗\"}" >/dev/null; fi
    echo "ask #$a"
  }
  ask "會議討論了什麼？" "\"answer_md\":\"## 重點\\n- 第一點是錄音功能。[[$rid@00:01]]\\n\\n[[$rid@00:05]]\",\"sources\":[$rid]"
  ask "這題會失敗嗎？" ""
  echo "knowledge seeded for #$rid"
fi
if [ "${PARITY:-}" = 1 ]; then
  rid=$(curl -sf -m 10 "$B/api/recordings?q=%E6%9C%83%E8%AD%B0%E6%B8%AC%E8%A9%A6" | j 'd[0]["id"]')
  curl -sf -m 10 $B/api/recordings/$rid/summaries -H "$H" -d '{"template_id":"meeting","language":"zh-TW"}' >/dev/null
  sid=$(curl -sf -m 10 $B/api/runner/claim -H "$H" -d "{\"runner\":\"$R\"}" | j '(d["job"] or {}).get("id","")')
  md='## 待辦\n| 項目 | 負責人 |\n|---|---|\n| 報價單 | 王小明 |\n| 合約 | 陳大華 |\n\n1. 確認時程\n2. 寄出報價\n\n> 下週再確認\n\n---\n```\nnpm run deploy\n```'
  curl -sf -m 10 $B/api/runner/summaries/$sid/result -H "$H" -d "{\"runner\":\"$R\",\"content_md\":\"$md\"}" >/dev/null
  echo "summary #$sid (markdown) on #$rid"
  if [ -n "${1:-}" ]; then
    q=$(curl -sf -m 10 $B/api/uploads -H "$H" -d "{\"filename\":\"排隊測試.m4a\",\"size\":$(stat -f%z "$1")}" | j 'd["recording_id"]')
    et=$(curl -sf -m 60 -X PUT --data-binary @"$1" $B/api/uploads/$q/1 | j 'd["etag"]')
    curl -sf -m 10 $B/api/uploads/$q/complete -H "$H" -d "{\"parts\":[{\"part\":1,\"etag\":\"$et\"}]}" >/dev/null
    echo "queued #$q 排隊測試"
  fi
  (cd "$(dirname "$0")/../../web" && npx wrangler d1 execute noteapp --local --persist-to "$STATE" \
    --command "UPDATE runners SET last_seen=datetime('now','-1 hour')" >/dev/null)
  echo "runners offline"
fi
