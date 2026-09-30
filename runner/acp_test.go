package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
)

// fakeAgent speaks just enough ACP; runs when the test binary is re-executed as the agent.
func fakeAgent() {
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(nil, 1<<24)
	send := func(v any) { b, _ := json.Marshal(v); fmt.Printf("%s\n", b) }
	recv := func() (m struct {
		ID     any
		Method string
		Params map[string]any
		Result map[string]any
		Error  map[string]any
	}) {
		if !in.Scan() {
			os.Exit(3)
		}
		json.Unmarshal(in.Bytes(), &m)
		return m
	}
	fail := func(why string) { fmt.Fprintln(os.Stderr, "fake agent: "+why); os.Exit(1) }
	chunk := func(s string) {
		send(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"sessionId": "s1",
			"update": map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": s}}}})
	}
	for {
		m := recv()
		switch m.Method {
		case "initialize":
			send(map[string]any{"jsonrpc": "2.0", "id": m.ID, "result": map[string]any{"protocolVersion": 1}})
		case "session/new":
			meta, _ := m.Params["_meta"].(map[string]any)
			if meta["disableBuiltInTools"] != true || !strings.Contains(fmt.Sprint(meta["claudeCode"]), "settingSources:[]") {
				fail(fmt.Sprint("bad _meta ", meta))
			}
			send(map[string]any{"jsonrpc": "2.0", "id": m.ID, "result": map[string]any{"sessionId": "s1"}})
		case "session/prompt":
			text := fmt.Sprint(m.Params["prompt"])
			if !strings.Contains(text, acpPreamble) {
				fail("missing preamble")
			}
			if strings.Contains(text, "CRASH") {
				fail("boom")
			}
			fmt.Println("not json log line")
			chunk("你好")
			send(map[string]any{"jsonrpc": "2.0", "id": "perm-1", "method": "session/request_permission", "params": map[string]any{}})
			if r := recv(); r.ID != "perm-1" || fmt.Sprint(r.Result) != "map[outcome:map[outcome:cancelled]]" {
				fail(fmt.Sprint("bad permission reply ", r))
			}
			send(map[string]any{"jsonrpc": "2.0", "id": 99, "method": "fs/read_text_file", "params": map[string]any{}})
			if r := recv(); r.Error["code"] != float64(-32601) {
				fail(fmt.Sprint("bad unknown-method reply ", r))
			}
			chunk("，世界")
			send(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{
				"update": map[string]any{"sessionUpdate": "agent_thought_chunk", "content": map[string]any{"type": "text", "text": "hmm"}}}})
			chunk("\n")
			stop := "end_turn"
			if strings.Contains(text, "REFUSE") {
				stop = "refusal"
			}
			send(map[string]any{"jsonrpc": "2.0", "id": m.ID, "result": map[string]any{"stopReason": stop}})
		}
	}
}

func TestMain(m *testing.M) {
	if os.Getenv("FAKE_ACP_AGENT") == "1" {
		fakeAgent()
		return
	}
	os.Exit(m.Run())
}

func TestACPAsk(t *testing.T) {
	t.Setenv("FAKE_ACP_AGENT", "1")
	cfg := Config{DataDir: t.TempDir(), ACPAgent: os.Args[0] + " -test.run=^$"}

	got, err := acpAsk(t.Context(), cfg, "hi")
	if err != nil || got != "你好，世界" {
		t.Fatalf("got %q, %v", got, err)
	}
	if _, err := acpAsk(t.Context(), cfg, "REFUSE"); err == nil || !strings.Contains(err.Error(), "stopReason refusal") {
		t.Fatalf("want stopReason error, got %v", err)
	}
	if _, err := acpAsk(t.Context(), cfg, "CRASH"); err == nil || !strings.Contains(err.Error(), "fake agent: boom") {
		t.Fatalf("want stderr tail in error, got %v", err)
	}
}
