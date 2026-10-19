package main

import (
	"encoding/json"
	"net"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSendLogs(t *testing.T) {
	dir := t.TempDir()
	oldPath, oldCopy, oldOpen := logFilePath, copyText, openURL
	defer func() { logFilePath, copyText, openURL = oldPath, oldCopy, oldOpen }()
	logFilePath = func() string { return filepath.Join(dir, "vanguard_log.txt") }
	var clip, opened string
	copyText = func(s string) error { clip = s; return nil }
	openURL = func(u string) { opened = u }

	h := testHub(t)
	conn, _ := fakeChar(t, h, "Zorbak", "BRD", nil)
	for i := 0; i < 300; i++ {
		m, _ := json.Marshal(map[string]any{"type": "log", "name": "Zorbak", "text": "Songs: line " + string(rune('a'+i%26)) + " " + strings.Repeat("x", i%7)})
		conn.WriteToUDP(m, h.conn.LocalAddr().(*net.UDPAddr))
		time.Sleep(time.Millisecond)
	}
	h.addLog(`Update installed from C:\Users\someone\Desktop\Vanguard`)
	time.Sleep(300 * time.Millisecond)
	// an old character not online now, from an earlier session in the file
	writeLogFile("Quillon", "Quillon: Songs: waiting 12s for NiTro")

	b, _ := os.ReadFile(logFilePath())
	if !strings.Contains(string(b), "| Zorbak | Zorbak: Songs: line") || !strings.Contains(string(b), "| app | Update installed") {
		t.Fatalf("the app's and the characters' messages go into the log file:\n%.400s", b)
	}
	h.handleCrashes(httptest.NewRecorder(), httptest.NewRequest("GET", "/api/crashes?do=logs&n=100", nil))
	if !strings.HasPrefix(opened, issuesURL+"?title=") {
		t.Fatalf("Send logs opens the same GitHub report page, got %q", opened)
	}
	u, _ := url.Parse(opened)
	body, title := u.Query().Get("body"), u.Query().Get("title")
	if !strings.Contains(title, "[logs]") || !strings.Contains(body, "Ctrl+V") || !strings.Contains(body, "waiting 12s for NiTro") {
		t.Errorf("the report says to paste the full log and shows the newest lines:\n%s\n%s", title, body)
	}
	if n := strings.Count(clip, "\n") - 3; n < 99 || n > 101 {
		t.Errorf("the last 100 lines go on the clipboard, got %d", n)
	}
	all := clip + body + title
	if strings.Contains(all, "Zorbak") || strings.Contains(all, "Quillon") || strings.Contains(all, `Users\someone`) {
		t.Errorf("character names (online or not) and the Windows user are taken out:\n%.600s", clip)
	}
	if !strings.Contains(clip, "CharA") || !strings.Contains(clip, "CharB") || !strings.Contains(clip, "<user>") {
		t.Errorf("...replaced, not deleted:\n%.600s", clip)
	}
	if len(opened) > 9000 {
		t.Errorf("the link stays short enough for a browser, got %d", len(opened))
	}
}
