package main

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

// A pretend character on the UDP link: answers "dump", collects "cfg" parts.
func fakeChar(t *testing.T, h *hub, name, job string, dump map[string]any) (*net.UDPConn, chan string) {
	c, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	got := make(chan string, 20)
	go func() {
		buf := make([]byte, 65535)
		for {
			n, _, err := c.ReadFromUDP(buf)
			if err != nil {
				return
			}
			msg := string(buf[:n])
			if msg == "cmd dump" {
				b, _ := json.Marshal(map[string]any{"type": "dump", "name": name, "data": dump})
				c.WriteToUDP(b, h.conn.LocalAddr().(*net.UDPAddr))
			}
			got <- msg
		}
	}()
	hello, _ := json.Marshal(map[string]any{"type": "state", "name": name})
	c.WriteToUDP(hello, h.conn.LocalAddr().(*net.UDPAddr))
	time.Sleep(100 * time.Millisecond)
	return c, got
}

func testHub(t *testing.T) *hub {
	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	h := &hub{conn: conn, chars: map[string]*character{}, updateNow: make(chan string, 1),
		dumps: map[string]chan json.RawMessage{}, jobs: map[string]string{}}
	go h.listen()
	t.Cleanup(func() { conn.Close(); os.RemoveAll(profilesDir()) })
	return h
}

func collect(got chan string, wait time.Duration) []string {
	var out []string
	deadline := time.After(wait)
	for {
		select {
		case m := <-got:
			out = append(out, m)
		case <-deadline:
			return out
		}
	}
}

func cfgText(msgs []string) string {
	var b strings.Builder
	for _, m := range msgs {
		if strings.HasPrefix(m, "cfg ") {
			parts := strings.SplitN(m, " ", 3)
			b.WriteString(parts[2])
		}
	}
	return b.String()
}

func TestProfileSaveLoad(t *testing.T) {
	h := testHub(t)
	big := strings.Repeat("Haste II>Daviant,", 600) // a profile bigger than one UDP message
	dump := map[string]any{"job": "WHM", "profile": "role=healer|ws=", "menu": "b=" + big, "settings": map[string]any{"heal": map[string]any{"cure_at": 60}}}
	_, got := fakeChar(t, h, "CharB", "WHM", dump)
	_, got2 := fakeChar(t, h, "CharC", "WHM", nil)

	rec := httptest.NewRecorder()
	h.handleProfiles(rec, httptest.NewRequest("GET", "/api/profiles?do=save&char=CharB&name=Odyssey+healer", nil))
	if _, err := os.Stat(profilePath("WHM", "Odyssey healer")); err != nil {
		t.Fatalf("saving should write a file in profiles: %v (%s)", err, rec.Body.String())
	}
	if ps := listProfiles(); len(ps) != 1 || ps[0].Name != "Odyssey healer" || ps[0].Job != "WHM" || ps[0].From != "CharB" {
		t.Errorf("the list should show the profile, got %+v", ps)
	}
	collect(got, 100*time.Millisecond)

	h.handleProfiles(httptest.NewRecorder(), httptest.NewRequest("GET", "/api/profiles?do=load&char=CharC&job=WHM&name=Odyssey+healer", nil))
	msgs := collect(got2, 300*time.Millisecond)
	if len(msgs) < 2 {
		t.Fatalf("a big profile goes in several parts, got %d messages", len(msgs))
	}
	var back map[string]any
	if err := json.Unmarshal([]byte(cfgText(msgs)), &back); err != nil {
		t.Fatalf("the parts put together are the profile: %v", err)
	}
	if back["name"] != "Odyssey healer" || back["job"] != "WHM" || !strings.Contains(back["menu"].(string), "Haste II>Daviant") {
		t.Errorf("profile content changed on the way: %v", back["name"])
	}

	rec = httptest.NewRecorder()
	h.handleProfiles(rec, httptest.NewRequest("GET", "/api/profiles?do=save&char=CharB&name=../evil", nil))
	if !strings.Contains(rec.Body.String(), "error") {
		t.Error("names with paths are refused")
	}
	rec = httptest.NewRecorder()
	h.handleProfiles(rec, httptest.NewRequest("GET", "/api/profiles?do=save&char=Nobody&name=x", nil))
	if !strings.Contains(rec.Body.String(), "isn't connected") {
		t.Error("saving from a character that isn't there says so")
	}
	h.handleProfiles(httptest.NewRecorder(), httptest.NewRequest("GET", "/api/profiles?do=delete&job=WHM&name=Odyssey+healer", nil))
	if len(listProfiles()) != 0 {
		t.Error("delete removes the file")
	}
}

func TestProfileLoadsByItself(t *testing.T) {
	h := testHub(t)
	dump := map[string]any{"job": "COR", "profile": "role=support|ws=", "menu": "m=follow"}
	conn, got := fakeChar(t, h, "CharB", "COR", dump)
	h.handleProfiles(httptest.NewRecorder(), httptest.NewRequest("GET", "/api/profiles?do=save&char=CharB&name=Rolls", nil))
	h.handleProfiles(httptest.NewRecorder(), httptest.NewRequest("GET", "/api/profiles?do=auto&char=CharB&job=COR&name=Rolls", nil))
	collect(got, 100*time.Millisecond)
	// The character reports it's on COR (logging in / job change): the profile follows by itself.
	prof, _ := json.Marshal(map[string]any{"type": "profile", "name": "CharB", "job": "COR"})
	conn.WriteToUDP(prof, h.conn.LocalAddr().(*net.UDPAddr))
	msgs := collect(got, 3*time.Second)
	if !strings.Contains(cfgText(msgs), `"name":"Rolls"`) {
		t.Errorf("the profile set to load by itself should be sent, got %v", msgs)
	}
	// Same job again (a refresh, not a change): not sent twice.
	conn.WriteToUDP(prof, h.conn.LocalAddr().(*net.UDPAddr))
	if msgs := collect(got, 2500*time.Millisecond); cfgText(msgs) != "" {
		t.Error("the profile is only sent when the job changes")
	}
}

func TestBigMessageInParts(t *testing.T) {
	h := testHub(t)
	c, _ := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	defer c.Close()
	big, _ := json.Marshal(map[string]any{"type": "profile", "name": "CharC", "job": "SCH", "pad": strings.Repeat("Regen V,", 2500)})
	text := string(big)
	var msgs []string
	for i, n := 0, (len(text)+5999)/6000; i < n; i++ {
		end := (i + 1) * 6000
		if end > len(text) {
			end = len(text)
		}
		msgs = append(msgs, fmt.Sprintf("vgpart 7 %d/%d %s", i+1, n, text[i*6000:end]))
	}
	for i := len(msgs) - 1; i >= 0; i-- { // out of order on purpose
		c.WriteToUDP([]byte(msgs[i]), h.conn.LocalAddr().(*net.UDPAddr))
	}
	time.Sleep(300 * time.Millisecond)
	h.mu.Lock()
	ch := h.chars["CharC"]
	h.mu.Unlock()
	if len(msgs) < 3 || ch == nil || ch.Profile["job"] != "SCH" {
		t.Fatalf("a profile sent in %d parts should arrive whole", len(msgs))
	}
}

func TestNearbyKept(t *testing.T) {
	h := testHub(t)
	conn, _ := fakeChar(t, h, "CharB", "WHM", nil)
	msg, _ := json.Marshal(map[string]any{"type": "nearby", "name": "CharB", "mobs": []any{map[string]any{"n": "Apex Bat", "c": 2, "d": 5}}})
	conn.WriteToUDP(msg, h.conn.LocalAddr().(*net.UDPAddr))
	time.Sleep(200 * time.Millisecond)
	rec := httptest.NewRecorder()
	h.handleState(rec, httptest.NewRequest("GET", "/api/state", nil))
	if !strings.Contains(rec.Body.String(), `"nearby":{`) || !strings.Contains(rec.Body.String(), "Apex Bat") {
		t.Errorf("the Look around answer should reach the panel, got %.300s", rec.Body.String())
	}
}
