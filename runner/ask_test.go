package main

import (
	"slices"
	"strings"
	"testing"
)

func TestParsePicked(t *testing.T) {
	valid := map[int64]bool{1: true, 2: true, 3: true, 5: true, 12: true}
	for _, c := range []struct {
		reply string
		want  []int64
	}{
		{"[12, 5, 1]", []int64{12, 5, 1}},
		{"```json\n[3, 2]\n```", []int64{3, 2}},
		{"根據[索引]，相關的是：[5,\"12\"] 這兩筆。", []int64{5, 12}},                   // prose with brackets first
		{`{"ids": [{"id": 2, "why": "提到 7 月"}, {"id": 99}]}`, []int64{2}}, // objects; unknown id dropped
		{"[1, 1, 42, 3, 2, 5, 12]", []int64{1, 3, 2}},                     // dedupe, invalid dropped, limit 3
		{"[]", nil},
		{"沒有相關錄音", nil},
	} {
		if got := parsePicked(c.reply, valid, 3); !slices.Equal(got, c.want) {
			t.Errorf("parsePicked(%q) = %v, want %v", c.reply, got, c.want)
		}
	}
}

func TestFitBudget(t *testing.T) {
	doc := func(id int64, n int) askDoc { return askDoc{ID: id, Transcript: strings.Repeat("字", n)} }
	kept, dropped := fitBudget([]askDoc{doc(1, 6), doc(2, 5), doc(3, 4)}, 10)
	if len(kept) != 2 || kept[0].ID != 1 || kept[1].ID != 3 || !slices.Equal(dropped, []int64{2}) {
		t.Errorf("kept %v dropped %v", kept, dropped)
	}
	kept, dropped = fitBudget([]askDoc{doc(1, 15), doc(2, 1)}, 10) // first alone over budget: cut, nothing else fits
	if len(kept) != 1 || kept[0].Transcript != strings.Repeat("字", 10) || !slices.Equal(dropped, []int64{2}) {
		t.Errorf("kept %v dropped %v", kept, dropped)
	}
}
