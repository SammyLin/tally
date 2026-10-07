package main

import (
	"slices"
	"strings"
	"testing"
)

func TestParseVocab(t *testing.T) {
	terms := func(ts []vocabTerm) []string {
		var out []string
		for _, x := range ts {
			out = append(out, x.Term)
		}
		return out
	}
	for _, c := range []struct {
		reply string
		want  []string
	}{
		{`[{"term":"EnergyQ","misheard":["能源Q"],"kind":"product"}]`, []string{"EnergyQ"}},
		{"好的，結果如下：\n```json\n[{\"term\": \"NHQ\"}, {\"term\": \"S&OR\"}]\n```", []string{"NHQ", "S&OR"}},
		{`前面[有括號]的說明 [{"term":"NHQ"}]`, []string{"NHQ"}},                                                      // prose with brackets first
		{`[{"term":"delta"},{"term":"Blocked"},{"term":" "},{"term":"NHQ"},{"term":"nhq"}]`, []string{"NHQ"}}, // vocab/skip (any case), empty, dupes
		{`[{"term":"` + strings.Repeat("長", 51) + `"},{"term":"OK"}]`, []string{"OK"}},                        // over 50 chars
		{"[]", nil},
		{"沒有建議", nil},
	} {
		if got := terms(parseVocab(c.reply, []string{"Delta"}, []string{"blocked"})); !slices.Equal(got, c.want) {
			t.Errorf("parseVocab(%q) = %v, want %v", c.reply, got, c.want)
		}
	}
	got := parseVocab(`[{"term":"EnergyQ","misheard":[" 能源Q ","EnergyQ",""]}]`, nil, nil)
	if len(got) != 1 || !slices.Equal(got[0].Misheard, []string{"能源Q"}) {
		t.Errorf("misheard not cleaned: %+v", got)
	}
	var many strings.Builder
	many.WriteString("[")
	for i := range 40 {
		if i > 0 {
			many.WriteString(",")
		}
		many.WriteString(`{"term":"T` + strings.Repeat("x", i) + `"}`)
	}
	many.WriteString("]")
	if n := len(parseVocab(many.String(), nil, nil)); n != vocabMaxTerms {
		t.Errorf("cap: got %d terms, want %d", n, vocabMaxTerms)
	}
}
