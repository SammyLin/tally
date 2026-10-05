package main

import (
	"reflect"
	"strings"
	"testing"
)

func TestSplitSentences(t *testing.T) {
	got := splitSentences([]Segment{
		{Start: 0, End: 10, Text: "你好。「好！」OK嗎？？"}, // 12 runes
		{Start: 10, End: 11, Text: "no end"},
		{Start: 11, End: 12, Text: " "},
	})
	want := []Segment{
		{0, 2.5, "你好。"},
		{2.5, 5.833, "「好！」"},
		{5.833, 10, "OK嗎？？"},
		{10, 11, "no end"},
	}
	for i := range got { // round away float noise
		got[i].Start, got[i].End = float64(int(got[i].Start*1000+0.5))/1000, float64(int(got[i].End*1000+0.5))/1000
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v\nwant %v", got, want)
	}
}

func TestParseCleanup(t *testing.T) {
	reply := "```text\n12\t你好。\n13 世界！ \n99\t不在批次\n廢話\n14\t\n```"
	got := parseCleanup(reply, map[int64]bool{12: true, 13: true, 14: true})
	want := map[int64]string{12: "你好。", 13: "世界！"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
	if got := parseCleanup("12\t好", map[int64]bool{12: true}); got[12] != "好" {
		t.Fatalf("unfenced: %v", got)
	}
}

func TestSummaryPrompt(t *testing.T) {
	const end = "\n\n逐字稿：\n[00:01] Sammy: 好"
	head := "使用者偏好（只調整語氣、重點與詳略，不要改變上面規定的段落結構）：\n"
	for _, tc := range []struct {
		name string
		s    jobSettings
		want string // text between the template rules and 逐字稿：; "" = no block
	}{
		{"empty", jobSettings{}, ""},
		{"blank strings", jobSettings{About: "  ", Vocab: []string{}}, ""},
		{"about only", jobSettings{About: "工程師"}, head + "- 關於使用者：工程師"},
		{"all", jobSettings{About: "A", ContentFocus: "B", Instructions: "C", Me: "Sammy", Vocab: []string{"Delta", "DEMP"}},
			head + "- 關於使用者：A\n- 內容重點：B\n- 格式與語氣：C\n- 錄音中的「Sammy」就是使用者本人；待辦事項中屬於使用者的請標註「（我）」。\n- 專有名詞：Delta、DEMP"},
		{"me and vocab", jobSettings{Me: "Sammy", Vocab: []string{"Delta"}},
			head + "- 錄音中的「Sammy」就是使用者本人；待辦事項中屬於使用者的請標註「（我）」。\n- 專有名詞：Delta"},
	} {
		got, err := summaryPrompt("meeting", "zh-TW", " [00:01] Sammy: 好\n", tc.s)
		if err != nil {
			t.Fatal(err)
		}
		old := strings.NewReplacer("{language}", "繁體中文（台灣）", "{transcript}", "[00:01] Sammy: 好").Replace(templates[0].Prompt)
		want := old
		if tc.want != "" {
			want = strings.TrimSuffix(old, end) + "\n\n" + tc.want + end
		}
		if got != want {
			t.Errorf("%s: got\n%s\nwant\n%s", tc.name, got, want)
		}
	}
	if _, err := summaryPrompt("nope", "en", "", jobSettings{}); err == nil {
		t.Error("unknown template accepted")
	}
}

func TestBuildCleanupPrompt(t *testing.T) {
	const line = "專有名詞表（只在讀音或字形明顯相近時才改成這些詞，不要硬套）：Delta、DEMP\n\n「上下文」區"
	for _, tc := range []struct {
		vocab []string
		has   bool
	}{{nil, false}, {[]string{}, false}, {[]string{"Delta", "DEMP"}, true}} {
		p := buildCleanupPrompt(tc.vocab, "B", "L", "A")
		if strings.Contains(p, line) != tc.has || strings.Contains(p, "專有名詞表") != tc.has || strings.Contains(p, "{") {
			t.Errorf("vocab %v: prompt\n%s", tc.vocab, p)
		}
		if !tc.has && !strings.Contains(p, "移到另一行。\n\n「上下文」區") { // same as before settings
			t.Errorf("vocab %v: layout changed\n%s", tc.vocab, p)
		}
	}
}
