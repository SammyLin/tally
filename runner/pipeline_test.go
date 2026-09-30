package main

import (
	"reflect"
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
