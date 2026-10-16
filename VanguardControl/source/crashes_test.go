package main

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

func TestCrashReports(t *testing.T) {
	os.Remove(crashPath())
	defer os.Remove(crashPath())
	h := testHub(t)
	conn, _ := fakeChar(t, h, "Zorbak", "WHM", nil)
	// the addon caught an error
	m, _ := json.Marshal(map[string]any{"type": "crash", "name": "Zorbak", "version": "0.29.0", "job": "WHM/SCH",
		"where": "event action", "err": "Vanguard/vg_x.lua:12: attempt to index a nil value (Zorbak's target)",
		"trace": "stack traceback:\n\t" + `C:\Users\someone\Desktop\Windower\addons\Vanguard\vg_x.lua:12`})
	conn.WriteToUDP(m, h.conn.LocalAddr().(*net.UDPAddr))
	conn.WriteToUDP(m, h.conn.LocalAddr().(*net.UDPAddr))
	time.Sleep(300 * time.Millisecond)
	list := loadCrashes()
	if len(list) != 1 || list[0].Count != 2 || list[0].Source != "addon" || list[0].Who != "Zorbak" {
		t.Fatalf("the addon's crash should be kept once, counted twice, got %+v", list)
	}
	// Send report: opens a GitHub "new issue" link with the details, names and user taken out
	var opened string
	openURL = func(u string) { opened = u }
	h.handleCrashes(httptest.NewRecorder(), httptest.NewRequest("GET", "/api/crashes?do=report&i=0", nil))
	if !strings.HasPrefix(opened, issuesURL+"?title=") {
		t.Fatalf("a GitHub issue link should open, got %q", opened)
	}
	u, _ := url.Parse(opened)
	body, title := u.Query().Get("body"), u.Query().Get("title")
	if !strings.Contains(title, "event action") || !strings.Contains(body, "attempt to index a nil value") || !strings.Contains(body, "vg_x.lua:12") {
		t.Errorf("the report should say what broke and where:\n%s\n%s", title, body)
	}
	if strings.Contains(body+title, "Zorbak") || strings.Contains(body, `Users\someone`) {
		t.Errorf("character names and the Windows user must be taken out:\n%s", body)
	}
	if !strings.Contains(body, "CharA") || !strings.Contains(body, "<user>") {
		t.Errorf("...replaced, not just deleted:\n%s", body)
	}
	if len(opened) > 9000 {
		t.Errorf("the link must stay short enough for a browser, got %d", len(opened))
	}
	if !loadCrashes()[0].Sent {
		t.Error("a sent report is marked sent")
	}
	// the app's own crashes: a panicking request and a background job
	srv := h.guardHTTP(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { panic("boom in a request") }))
	rec := httptest.NewRecorder()
	srv.ServeHTTP(rec, httptest.NewRequest("GET", "/api/x", nil))
	if rec.Code != 500 {
		t.Error("a panicking request answers 500 instead of killing the app")
	}
	runs := 0
	done := make(chan bool, 3)
	h.safeGo("test job", func() {
		runs++
		done <- true
		if runs == 1 {
			panic("boom in a job")
		}
	})
	<-done
	select {
	case <-done:
	case <-time.After(8 * time.Second):
		t.Error("a background job that panicked starts again")
	}
	srcs := map[string]bool{}
	for _, c := range loadCrashes() {
		srcs[c.Where] = true
		if c.Source == "app" && !strings.Contains(c.Trace, "goroutine") {
			t.Error("app crashes keep their stack")
		}
	}
	if !srcs["request /api/x"] || !srcs["test job"] {
		t.Errorf("both app crashes should be kept, got %v", srcs)
	}
	// manual "Report a problem" and dismiss
	opened = ""
	h.handleCrashes(httptest.NewRecorder(), httptest.NewRequest("GET", "/api/crashes?do=problem", nil))
	if !strings.Contains(opened, "%5Bproblem%5D") && !strings.Contains(opened, "[problem]") {
		t.Errorf("Report a problem opens an empty problem report, got %q", opened)
	}
	n := len(loadCrashes())
	h.handleCrashes(httptest.NewRecorder(), httptest.NewRequest("GET", "/api/crashes?do=dismiss&i=0", nil))
	if len(loadCrashes()) != n-1 {
		t.Error("dismiss removes a report")
	}
}
