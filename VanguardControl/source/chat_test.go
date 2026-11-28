package main

import (
	"encoding/json"
	"net"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// App 2.1.0 (CurePlease audit 3.3 / F80): the read-only Game chat tab. The addon's "chat" messages are kept in order,
// each line once (a line sent twice, a new addon load), with its kind; the same line seen by two characters is marked
// so "all characters" shows it once.
func chatMsg(sid string, lines ...[3]any) map[string]any {
	var l []any
	for _, x := range lines {
		l = append(l, map[string]any{"i": float64(x[0].(int)), "m": float64(x[1].(int)), "t": x[2]})
	}
	// through JSON, as it arrives from the addon
	raw, _ := json.Marshal(map[string]any{"type": "chat", "sid": sid, "lines": l})
	var m map[string]any
	json.Unmarshal(raw, &m)
	return m
}

func TestChatBook(t *testing.T) {
	b := &chatBook{seen: map[string]chatSeen{}}
	now := time.Now()
	if n := b.add("CharA", chatMsg("s1", [3]any{1, 12, "Pal>> hi there"}, [3]any{2, 13, "(CharB) pull"}, [3]any{3, 36, "CharA hits the Crab."}), now); n != 3 {
		t.Fatalf("3 new lines kept, got %d", n)
	}
	l := b.since(0)
	if len(l) != 3 || l[0].Kind != "tell" || l[1].Kind != "party" || l[2].Kind != "game" || l[0].Who != "CharA" || l[0].Text != "Pal>> hi there" {
		t.Fatalf("lines / kinds wrong: %+v", l)
	}
	// sent again (the addon only sends new ones, but a repeat must not double them)
	if n := b.add("CharA", chatMsg("s1", [3]any{3, 36, "CharA hits the Crab."}, [3]any{4, 5, "(CharA) ok"}), now); n != 1 {
		t.Fatalf("only line 4 is new, got %d", n)
	}
	// the same party line from another character within 3 s: kept for that character, marked dup
	b.add("CharB", chatMsg("t1", [3]any{1, 13, "(CharB) pull"}), now.Add(time.Second))
	last := b.since(0)[len(b.since(0))-1]
	if last.Who != "CharB" || !last.Dup {
		t.Fatalf("CharB's copy of the party line should be marked dup: %+v", last)
	}
	// later than 3 s: not a duplicate
	b.add("CharB", chatMsg("t1", [3]any{2, 13, "(CharA) ok"}), now.Add(5*time.Second))
	if last = b.since(0)[len(b.since(0))-1]; last.Dup {
		t.Fatalf("a line 5 s later is not a duplicate: %+v", last)
	}
	// a new addon load (new sid): its ids start at 1 again and are taken
	if n := b.add("CharA", chatMsg("s2", [3]any{1, 9, "Someone : hello"}), now); n != 1 {
		t.Fatalf("a reloaded addon's line 1 is new, got %d", n)
	}
	// since(id): only newer lines
	all := b.since(0)
	if got := b.since(all[len(all)-2].ID); len(got) != 1 || got[0].Text != "Someone : hello" {
		t.Fatalf("since: %+v", got)
	}
	// control characters, bad UTF-8, long text
	b.add("CharA", chatMsg("s2", [3]any{2, 1, "a\x07b\nc  d\xff" + strings.Repeat("x", 400)}), now)
	if last = b.since(0)[len(b.since(0))-1]; !strings.HasPrefix(last.Text, "a b c d") || len(last.Text) != chatMaxText || last.Kind != "say" {
		t.Fatalf("text not cleaned: %q (%d)", last.Text[:12], len(last.Text))
	}
	// only the last chatKeep lines are kept
	for i := 3; i < 3+chatKeep+10; i++ {
		b.add("CharA", chatMsg("s2", [3]any{i, 36, "line"}), now.Add(10*time.Second))
	}
	if n := len(b.since(0)); n != chatKeep {
		t.Fatalf("kept %d lines, want %d", n, chatKeep)
	}
	// empty lines are skipped
	if n := b.add("CharC", chatMsg("u", [3]any{1, 36, "   "}), now); n != 0 {
		t.Fatalf("an empty line is not kept")
	}
}

func TestChatKinds(t *testing.T) {
	want := map[int]string{1: "say", 9: "say", 2: "shout", 10: "shout", 11: "yell", 4: "tell", 12: "tell", 5: "party", 13: "party",
		6: "ls", 14: "ls", 214: "ls", 7: "emote", 15: "emote", 212: "unity", 0: "game", 121: "game", 36: "game"}
	for m, k := range want {
		if got := chatKind(m); got != k {
			t.Errorf("mode %d: %q, want %q", m, got, k)
		}
	}
}

// The hub takes "chat" messages from the addon, serves them on /api/chat, and says "vgapp" to online characters.
func TestChatHubAndHello(t *testing.T) {
	chats = &chatBook{seen: map[string]chatSeen{}}
	h := testHub(t)
	addon, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer addon.Close()
	to := h.conn.LocalAddr().(*net.UDPAddr)
	send := func(m map[string]any) { b, _ := json.Marshal(m); addon.WriteToUDP(b, to) }
	send(map[string]any{"type": "state", "name": "CharA", "mp": 900.0, "job": "WHM99/SCH49", "status": "Engaged"})
	send(map[string]any{"type": "chat", "name": "CharA", "sid": "x", "lines": []any{map[string]any{"i": 1, "m": 12, "t": "Pal>> hello"}}})
	var lines []chatLine
	for i := 0; i < 50 && len(lines) == 0; i++ {
		time.Sleep(20 * time.Millisecond)
		rec := httptest.NewRecorder()
		h.handleChat(rec, httptest.NewRequest("GET", "/api/chat?since=0", nil))
		var body struct{ Lines []chatLine }
		json.Unmarshal(rec.Body.Bytes(), &body)
		lines = body.Lines
	}
	if len(lines) != 1 || lines[0].Who != "CharA" || lines[0].Kind != "tell" || lines[0].Text != "Pal>> hello" {
		t.Fatalf("/api/chat: %+v", lines)
	}
	rec := httptest.NewRecorder()
	h.handleChat(rec, httptest.NewRequest("GET", "/api/chat?since=1", nil))
	if !strings.Contains(rec.Body.String(), `"lines":[]`) {
		t.Fatalf("nothing after id 1: %s", rec.Body.String())
	}
	if n := h.sayHello(time.Now()); n != 1 {
		t.Fatalf("vgapp sent to %d characters, want 1", n)
	}
	addon.SetReadDeadline(time.Now().Add(time.Second))
	buf := make([]byte, 64)
	n, _, err := addon.ReadFromUDP(buf)
	if err != nil || string(buf[:n]) != "vgapp" {
		t.Fatalf("the addon got %q (%v), want vgapp", buf[:n], err)
	}
	if n := h.sayHello(time.Now().Add(10 * time.Second)); n != 0 {
		t.Fatalf("a character silent for 10 s is not told (%d)", n)
	}
}
