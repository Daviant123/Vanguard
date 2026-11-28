// Game chat (2.1.0, CurePlease audit 3.3 / F80): a read-only view of what each character's game shows.
//
// The addon only keeps and sends its chat while this app is there: every 2 s the app says "vgapp" to each online
// character (helloLoop), and the addon then sends {"type":"chat","name":..,"sid":..,"lines":[{"i":n,"m":mode,"t":text}]}
// with the lines the app hasn't had yet (vg_bridge.flush_chat). sid changes with each addon load (its ids start over).
// Nothing is ever typed into the game from here: the page only shows the lines (GET /api/chat?since=<id>).
package main

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	chatKeep      = 300             // lines kept for the page (all characters together)
	chatDupWindow = 3 * time.Second // the same line from two characters within this: shown once in "all characters"
	chatMaxText   = 300
	helloEvery    = 2 * time.Second // the addon stops its chat buffer 6 s after the last "vgapp"
)

type chatLine struct {
	ID   int    `json:"id"`
	Time string `json:"time"`
	Who  string `json:"who"`
	Kind string `json:"kind"` // tell, party, ls, say, shout, yell, emote, unity or game (everything else)
	Text string `json:"text"`
	Dup  bool   `json:"dup,omitempty"` // another character already showed the same line (party chat, battle text)
	at   time.Time
}

type chatSeen struct {
	sid  string
	last int
}

type chatBook struct {
	mu    sync.Mutex
	lines []chatLine
	next  int
	seen  map[string]chatSeen
}

var chats = &chatBook{seen: map[string]chatSeen{}}

// chatKind: the game's text mode (the 'incoming text' event's colour) -> what kind of line it is. Own lines and
// others' lines have their own modes (say 1 / 9, shout 2 / 10, yell 3 / 11, tell 4 / 12, party 5 / 13, linkshell
// 6 / 14, emote 7 / 15, linkshell 2 213 / 214, unity 211 / 212); everything else is game text (battle, system).
func chatKind(mode int) string {
	switch mode {
	case 1, 9:
		return "say"
	case 2, 10:
		return "shout"
	case 3, 11:
		return "yell"
	case 4, 12:
		return "tell"
	case 5, 13:
		return "party"
	case 6, 14, 213, 214:
		return "ls"
	case 7, 15:
		return "emote"
	case 211, 212:
		return "unity"
	}
	return "game"
}

// cleanChatText: printable text only (the addon already strips the game's colour codes), one line, at most chatMaxText.
func cleanChatText(s string) string {
	if !utf8.ValidString(s) {
		s = strings.ToValidUTF8(s, "")
	}
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, s)
	s = strings.Join(strings.Fields(s), " ")
	if len(s) > chatMaxText {
		s = s[:chatMaxText]
		for !utf8.ValidString(s) {
			s = s[:len(s)-1]
		}
	}
	return s
}

func numInt(v any) int {
	switch x := v.(type) {
	case float64:
		return int(x)
	case int:
		return x
	case json.Number:
		n, _ := x.Int64()
		return int(n)
	}
	return 0
}

// add takes one "chat" message from a character; returns how many new lines were kept.
func (b *chatBook) add(who string, msg map[string]any, now time.Time) int {
	sid, _ := msg["sid"].(string)
	lines, _ := msg["lines"].([]any)
	b.mu.Lock()
	defer b.mu.Unlock()
	st, ok := b.seen[who]
	if !ok || st.sid != sid { // a new addon load: its line numbers start again at 1
		st = chatSeen{sid: sid}
	}
	added := 0
	for _, raw := range lines {
		m, _ := raw.(map[string]any)
		if m == nil {
			continue
		}
		i := numInt(m["i"])
		if i <= st.last { // already had it (sent twice)
			continue
		}
		st.last = i
		t, _ := m["t"].(string)
		text := cleanChatText(t)
		if text == "" {
			continue
		}
		kind := chatKind(numInt(m["m"]))
		dup := false
		for j := len(b.lines) - 1; j >= 0 && now.Sub(b.lines[j].at) <= chatDupWindow; j-- {
			if l := b.lines[j]; l.Who != who && !l.Dup && l.Kind == kind && l.Text == text {
				dup = true
				break
			}
		}
		b.next++
		b.lines = append(b.lines, chatLine{ID: b.next, Time: now.Format("15:04:05"), Who: who, Kind: kind, Text: text, Dup: dup, at: now})
		added++
	}
	b.seen[who] = st
	if len(b.lines) > chatKeep {
		b.lines = append([]chatLine(nil), b.lines[len(b.lines)-chatKeep:]...)
	}
	return added
}

// since: the lines after this id (0 = all that are kept).
func (b *chatBook) since(id int) []chatLine {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := []chatLine{}
	for _, l := range b.lines {
		if l.ID > id {
			out = append(out, l)
		}
	}
	return out
}

func (h *hub) handleChat(w http.ResponseWriter, r *http.Request) {
	var since int
	fmt.Sscan(r.URL.Query().Get("since"), &since)
	body, _ := json.Marshal(map[string]any{"lines": chats.since(since)})
	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

// helloTargets: the characters online now (state in the last 5 s) and where their addon listens.
func (h *hub) helloTargets(now time.Time) []*net.UDPAddr {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := []*net.UDPAddr{}
	for _, c := range h.chars {
		if c.addr != nil && now.Sub(c.LastSeen) < 5*time.Second {
			out = append(out, c.addr)
		}
	}
	return out
}

// sayHello: "vgapp" to every online character (the addon keeps its chat buffer while it hears it).
func (h *hub) sayHello(now time.Time) int {
	n := 0
	for _, a := range h.helloTargets(now) {
		if _, err := h.conn.WriteToUDP([]byte("vgapp"), a); err == nil {
			n++
		}
	}
	return n
}

func (h *hub) helloLoop() {
	for {
		h.sayHello(time.Now())
		time.Sleep(helloEvery)
	}
}
