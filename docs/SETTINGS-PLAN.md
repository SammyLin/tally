# Settings (Plaud-style) — plan, decisions in progress

> Status: planning, not implemented. Fold into `docs/SPEC.md` once settled.
> Branch: `settings`, created with `wt switch --create settings` after v2 is committed (D25).

Scope: AI settings, language + transcript cleanup, speaker management, custom vocabulary. Memory: skipped. "Sync speaker labels": not applicable (one Worker).

## Decisions (grilling round 1, 2026-10-05)

| # | Question | Decision |
|---|---|---|
| D1 | Uncommitted Speaker ID v2 changes on main vs new worktree | **Deferred.** Record the plan here first; decide branching later. |
| D2 | Transcription language options | `zh`, `en`, `ja`, `auto` |
| D3 | Per-recording language | Yes: `recordings.language` (NULL = settings default), select on upload/record, reused on re-transcribe |
| D4 | Profile shape | One free-text "關於我" (≤ 500 chars), seeded: "Sr. Engineer，Software／AI，主要用於內部會議" |
| D5 | Where AI settings (about / content focus / instructions) apply | Summary prompt only (not cleanup, not title) |
| D6 | Cleanup off → auto title? | Title still generated |
| D7 | Auto-label off → suggestions? | Suggestions「可能是 X？」still shown; only auto-renaming stops |
| D8 | "My voice profile" | Summary prompt knows「我 = X」 AND UI marks（我）next to that speaker |
| D9 | Rename person to an existing name | Merge (voiceprints + speakers move to the existing person), UI confirms first |
| D10 | Delete person | Voiceprints deleted; user-confirmed speaker names kept (person_id → NULL); auto-labelled speakers revert to `Speaker N`; then rematch |
| D11 | Vocabulary "industry" field | Not built; industry goes in 關於我 |
| D12 | Settings change → existing recordings/summaries | No automatic reprocessing; only new jobs. User re-runs manually |
| D13 | Save UX | One「儲存」button (not autosave) |

## Decisions (round 2)

| # | Question | Decision |
|---|---|---|
| D14 | Language on re-transcribe | 「重新轉錄」opens a small dialog with a language select (default = recording's language) |
| D15 | Summary default language | Derived: `zh`/`auto` → zh-TW, `en` → en, `ja` → ja; still changeable per summary |
| D16 | Closing settings with unsaved changes | In-dialog bar「有未儲存的變更，放棄？」(no native confirm) |
| D17 | Person rename/delete vs Save button | Immediate, each with its own confirm (merge: D9; delete: "N 個聲紋會刪除"). Only settings fields use Save |
| D18 | Which persons are listed | All `people`, with print count; name-only entries deletable (cleans 最近使用的名字) |
| D19 | `me` storage | Person id picked from the persons list; follows renames/merges |
| D20 | Vocab over whisper prompt limit (~224 tokens) | Fill in list order until full; cleanup/summary get all; UI shows「前 N 個詞會送進語音辨識」 |
| D21 | Vocab enable toggle | None; empty list = off (drop `vocab_enabled`) |

## Decisions (round 3)

| # | Question | Decision |
|---|---|---|
| D22 | Custom instructions vs template structure | Template structure wins; settings go in a「使用者偏好」block (tone, focus, detail only) |
| D23 | Vocab strength in cleanup | Replace only on clear sound/shape match (e.g.「德他」→ Delta); never force terms |
| D24 | Old runner (home-macmini) ignoring `language` | Accept; update home-macmini together. No capability negotiation |
| D25 | When to start | Ready: commit Speaker ID v2 on main → `wt switch --create settings` → implement (supersedes D1 deferral) |

## Draft design (updated as decisions land)

### Data — migration `0007_settings.sql`
```sql
CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);  -- value = JSON
ALTER TABLE recordings ADD COLUMN language TEXT;                   -- NULL = settings.stt_lang
```

| key | type | used by |
|---|---|---|
| `about` | string ≤ 500 | summary prompt |
| `content_focus` | string ≤ 500 (default: 重點與結論／待辦與下一步／風險與未決問題) | summary prompt |
| `instructions` | string ≤ 500 (default: 簡潔、正式、結構化) | summary prompt |
| `stt_lang` | `zh\|en\|ja\|auto` (default `zh`) | whisper `-l`, Groq `language` |
| `cleanup` | bool (default true) | runner skips ACP cleanup when false |
| `auto_label` | bool (default true) | `rematch` auto-labels only when true |
| `me` | person id \| null (D19; merge repoints it) | summary prompt, UI（我） |
| `vocab` | string[] (≤ 200, each ≤ 50 chars; empty = off, D21) | whisper/Groq prompt (list order, capped, D20), cleanup + summary prompts |

### Worker API
- `GET /api/settings` (merged with defaults), `PUT /api/settings` (partial, validated per key, unknown key → 400).
- `GET /api/persons` → all people `[{id, name, prints, speakers, last_used_at}]` (D18).
- `PATCH /api/persons/{id} {name}` → rename (+ speakers.display_name where person_id); existing name → merge (D9).
- `DELETE /api/persons/{id}` → D10.
- `rematch()` reads `auto_label` (D7).
- `/api/runner/claim`: job carries `settings` (runner-relevant subset); recording job carries `language`.
- `POST /api/uploads` accepts `language?`; re-transcribe accepts `language?`.

### Runner
- `job` gains `Language`, `Settings`. Missing (old Worker) → current env behaviour.
- `stt.go`: `-l` from job; vocab appended to the whisper/Groq prompt, capped ~200 tokens; `dropPromptEcho` already filters echoes.
- `pipeline.go`: skip `cleanup()` when `cleanup=false` (title still runs, D6); cleanup prompt gets a「專有名詞」line; summary prompt gets a block (關於我 / 重點 / 指示 / 我是 X / 詞彙), empty parts omitted.

### UI
- ⚙ in sidebar → settings `<dialog>`, sections: AI / 語言與逐字稿 / 講者 / 詞彙, one「儲存」button for fields (D13), unsaved-changes bar (D16); person rename/merge/delete act immediately (D17).
- Re-transcribe → language dialog (D14). Summary language select defaults per D15.
- Language select on import/record (D3).
- Speaker labels: （我）mark (D8).

### Rollout
Migrate D1 → deploy Worker → update runners. Old runners ignore new job fields.

## Open questions
None — design tree closed 2026-10-05.

## Contract (frozen for parallel implementation)

Ownership: **Worker agent** = `web/src/**`, `web/migrations/0007_settings.sql`, `web/test/**`, `web/package.json` test script. **Runner agent** = `runner/**`. **UI agent** = `web/public/index.html`. Nobody else edits another's files. Nobody commits.

### Settings object (GET /api/settings, response of PUT)
```json
{
  "about": "Sr. Engineer，Software／AI，主要用於內部會議",
  "content_focus": "標出重點與最終結論；整理待辦事項與下一步；指出潛在風險、問題與未決事項。",
  "instructions": "簡潔扼要；正式、專業的語氣；使用清楚的結構化格式。",
  "stt_lang": "zh",
  "cleanup": true,
  "auto_label": true,
  "me": null,
  "vocab": []
}
```
Values above are the defaults (a missing row = default). `PUT /api/settings` takes any subset; validation (400 with message on failure): `about/content_focus/instructions` string ≤ 500 chars (trimmed); `stt_lang` ∈ `zh|en|ja|auto`; `cleanup/auto_label` boolean; `me` null or id of an existing person; `vocab` array of strings, each trimmed, empty dropped, ≤ 50 chars, deduped (first wins, case-sensitive), ≤ 200 items. Unknown key → 400. Returns the full merged object.

### Persons
- `GET /api/persons` → `[{id, name, prints, speakers, last_used_at}]` ordered by `last_used_at DESC, id DESC`. `prints` = voiceprint count (any model), `speakers` = speakers with that person_id.
- `PATCH /api/persons/{id}` `{name, merge?: boolean}`: trim, 1–100 chars, not a default `Speaker N` name (400).
  - name unused → rename `people.name`, and `speakers.display_name` where `person_id = id`.
  - name belongs to another person and `merge !== true` → **409** `{detail, existing_id}`.
  - with `merge: true` → move voiceprints + speakers (person_id, display_name) + `suggest_person_id` to the existing person, repoint `settings.me` if it pointed at the merged one, delete the old person.
  - Returns `GET /api/persons` result. Then `rematch()` all.
- `DELETE /api/persons/{id}` → delete person (voiceprints cascade); speakers with `auto=1` and that person → default `Speaker k` name (same numbering rule as rematch), person_id NULL, auto 0; speakers with `auto=0` keep their name, person_id NULL; clear `settings.me` if it was this person; `rematch()` all. Returns `{ok:true}`.
- 404 for unknown id.

### Recording language
- `recordings.language` (NULL = settings default). `GET /api/recordings/{id}` → `recording.language` (raw column, may be null).
- `POST /api/uploads` accepts optional `language` ∈ `zh|en|ja|auto` (400 otherwise).
- `POST /api/recordings/{id}/retranscribe` accepts an optional JSON body `{language?}`; a request with no body/no JSON Content-Type keeps working (language unchanged).

### Runner claim (`POST /api/runner/claim`)
Recording job adds:
```json
{"language": "zh", "settings": {"cleanup": true, "vocab": ["Delta", "DEMP"]}}
```
`language` = `recordings.language ?? settings.stt_lang`. Summary job adds:
```json
{"settings": {"about": "...", "content_focus": "...", "instructions": "...", "me": "Sammy", "vocab": [...]}}
```
`me` = the person's **name** or null. Old runners ignore these fields; a new runner seeing them absent behaves as before (language = `WHISPER_LANG`, cleanup on, no vocab, no preference block).

### Matching
`rematch()` reads `auto_label`; when false, no speaker gets auto=1 (existing auto=1 labels revert like a non-match) but suggestions are still computed for all open speakers (those that would have been auto-labelled get the suggestion instead).

### Runner prompts
- whisper `-l <language>` (`auto` passes `auto`); Groq: omit `language` for `auto`. `sttPrompt(lang, vocab)`: zh example sentence (only for zh) + vocab joined by `、` appended in list order while the whole prompt stays ≤ ~200 tokens (estimate: 1 token per CJK rune, ~1 per 4 ASCII chars; conservative). Same prompt to Groq.
- `cleanup=false` → skip `cleanup()`, title still runs.
- Cleanup prompt, only when vocab non-empty: a line「專有名詞表（只在讀音或字形明顯相近時才改成這些詞，不要硬套）：A、B、C」.
- Summary prompt: template text unchanged, plus before `逐字稿：` a block, only non-empty parts:
  ```
  使用者偏好（只調整語氣、重點與詳略，不要改變上面規定的段落結構）：
  - 關於使用者：<about>
  - 內容重點：<content_focus>
  - 格式與語氣：<instructions>
  - 錄音中的「<me>」就是使用者本人；待辦事項中屬於使用者的請標註「（我）」。
  - 專有名詞：A、B、C
  ```

### UI
- ⚙ 設定 entry in sidebar → `<dialog>` with four sections: AI（關於我、內容重點、自訂指示）/ 語言與逐字稿（轉錄語言、自動清理）/ 講者（自動標記、我是誰 select from persons、persons list with rename + delete）/ 詞彙（chip input, shows「前 N 個詞會送進語音辨識」using the same estimate as runner）.
- Fields: one「儲存」button → PUT; closing with unsaved changes shows in-dialog bar「有未儲存的變更」[放棄][繼續編輯]. Persons rename/delete act immediately with in-dialog confirm (409 → 「X 已存在，要合併嗎？」→ PATCH with merge:true; delete → 「刪除 X？N 個聲紋會一併刪除」).
- Import / record: language select (default settings.stt_lang) sent as `language` on POST /api/uploads.
- Re-transcribe → small dialog with language select (default recording.language ?? settings.stt_lang) → POST retranscribe `{language}`.
- Summary language select default: zh/auto → zh-TW, en → en, ja → ja.
- Speaker label whose person_id == settings.me gets a「（我）」mark.
- No native alert/confirm/prompt.
