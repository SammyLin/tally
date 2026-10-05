package main

import (
	"encoding/binary"
	"math"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func TestSplit2(t *testing.T) {
	a, b := []float32{1, 0.1, 0}, []float32{0.1, 1, 0}
	jit := func(v []float32, i int) []float32 {
		return []float32{v[0] + float32(i%3)*0.05, v[1], v[2] + float32(i%2)*0.05}
	}
	var two, one [][]float32
	for i := range 8 {
		two = append(two, jit([][]float32{a, b}[i%2], i))
		one = append(one, jit(a, i))
	}
	lab, gap := split2(two)
	if gap < 0.5 || !slices.Equal(lab, []int{0, 1, 0, 1, 0, 1, 0, 1}) {
		t.Fatalf("two voices: gap %.2f labels %v", gap, lab)
	}
	if _, gap := split2(one); gap >= 0.2 {
		t.Fatalf("one voice split: gap %.2f", gap)
	}
}

func TestAssignSpeakers(t *testing.T) {
	turns := []Turn{{0, 5, 0}, {5, 9, 1}, {9.5, 12, 0}, {20, 25, 1}}
	segs := []Segment{
		{Start: 1, End: 4},     // inside speaker 0
		{Start: 4, End: 8},     // 1s of 0, 3s of 1
		{Start: 8.5, End: 11},  // 0.5s of 1, 1.5s of 0
		{Start: 14, End: 16},   // gap: nearest is turn ending at 12 (0)
		{Start: 17.5, End: 19}, // gap: nearest is turn starting at 20 (1)
	}
	if got, want := assignSpeakers(segs, turns), []int{0, 1, 0, 0, 1}; !slices.Equal(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	if got := assignSpeakers(segs, nil); !slices.Equal(got, make([]int, len(segs))) {
		t.Fatalf("no turns: got %v", got)
	}
}

func TestOpenWav(t *testing.T) {
	le := binary.LittleEndian
	var b []byte
	b = append(b, "RIFF\x00\x00\x00\x00WAVE"...)
	b = append(b, "fmt \x10\x00\x00\x00"...)
	b = le.AppendUint16(b, 1)
	b = le.AppendUint16(b, 1)
	b = le.AppendUint32(b, 16000)
	b = le.AppendUint32(b, 32000)
	b = le.AppendUint16(b, 2)
	b = le.AppendUint16(b, 16)
	b = append(b, "LIST\x03\x00\x00\x00abc\x00"...) // odd size, padded
	b = append(b, "data\x06\x00\x00\x00"...)
	for _, v := range []int16{0, 16384, -32768} {
		b = le.AppendUint16(b, uint16(v))
	}
	p := filepath.Join(t.TempDir(), "a.wav")
	if err := os.WriteFile(p, b, 0o644); err != nil {
		t.Fatal(err)
	}
	w, err := openWav(p)
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	x, err := w.read(1, 5)
	if w.rate != 16000 || w.n != 3 || err != nil || !slices.Equal(x, []float32{0.5, -1}) {
		t.Fatalf("rate=%d n=%d x=%v err=%v", w.rate, w.n, x, err)
	}
}

func TestVoiceSpans(t *testing.T) {
	segs := []Segment{{Start: 0, End: 1.5}, {Start: 10, End: 40.75}, {Start: 50, End: 55.75}, {Start: 60, End: 100.75}}
	// trimmed: 0.75 s (dropped), 30 s, 5 s, 40 s → longest first, capped at 60 s total
	got := voiceSpans(segs, 60)
	want := []Segment{{Start: 60.25, End: 100.25}, {Start: 10.25, End: 30.25}}
	if !slices.Equal(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
	if got := voiceSpans(segs, 40.5); len(got) != 1 { // 0.5 s left is under the 1 s minimum
		t.Fatalf("cap: got %v", got)
	}
}

func TestMeanNormalized(t *testing.T) {
	got := meanNormalized([][]float32{{3, 0}, {0, 10}}) // scale-independent: (1,0)+(0,1) → (√½, √½)
	if d := math.Abs(float64(got[0]) - math.Sqrt2/2); d > 1e-6 || got[0] != got[1] || math.Abs(norm(got)-1) > 1e-6 {
		t.Fatalf("got %v", got)
	}
}

func TestMergeTurns(t *testing.T) {
	a, b := []float32{1, 0.1, 0}, []float32{0, 0.1, 1}
	turns := []Turn{
		{0, 20, 7},        // A, chunk 0
		{20, 40, 3},       // B
		{40, 50, 9},       // A again under another label: merged (cosine > 0.5)
		{50, 60, 1 << 16}, // B in chunk 1, 10 s
		{60, 65, 5},       // short (<30 s) cluster nearer B than A, but below mergeSim: folded into B
		{65, 65.5, 8},     // no embedding: dropped
	}
	embs := [][]float32{a, b, {0.9, 0.2, 0.1}, b, {0, 1, 0.3}, nil} // last: cosine 0.38 to B, 0.09 to A
	got := mergeTurns(turns, embs)
	want := []Turn{{0, 20, 0}, {20, 40, 1}, {40, 50, 0}, {50, 60, 1}, {60, 65, 1}}
	if !slices.Equal(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
}
