package main

import (
	"encoding/json"
	"net"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestStopTimer(t *testing.T) {
	h := testHub(t)
	now := time.Date(2026, 10, 16, 1, 0, 0, 0, time.Local)
	timerNow = func() time.Time { return now }
	defer func() { timerNow = time.Now }()
	connB, gotB := fakeChar(t, h, "CharB", "WHM", nil)
	_, gotA := fakeChar(t, h, "CharA", "BLU", nil)
	// CharB follows CharA, so CharA is the leader
	st, _ := json.Marshal(map[string]any{"type": "state", "name": "CharB", "leader": "CharA"})
	connB.WriteToUDP(st, h.conn.LocalAddr().(*net.UDPAddr))
	time.Sleep(100 * time.Millisecond)
	call := func(q string) map[string]any {
		rec := httptest.NewRecorder()
		h.handleTimer(rec, httptest.NewRequest("GET", "/api/timer?"+q, nil))
		var m map[string]any
		json.Unmarshal(rec.Body.Bytes(), &m)
		return m
	}
	m := call("do=set&mins=90&action=logout&who=alts")
	if m["left"].(float64) != 90*60 || m["action"] != "logout" {
		t.Fatalf("90 minutes, log out: got %v", m)
	}
	now = now.Add(89 * time.Minute)
	h.checkTimer()
	if len(collect(gotB, 150*time.Millisecond)) != 0 {
		t.Error("nothing happens before the time")
	}
	now = now.Add(2 * time.Minute)
	h.checkTimer()
	b := strings.Join(collect(gotB, 300*time.Millisecond), ",")
	if b != "cmd off,cmd logout" {
		t.Errorf("time's up: the alt stops and logs out, got %q", b)
	}
	if a := collect(gotA, 200*time.Millisecond); len(a) != 0 {
		t.Errorf("'alts only' leaves the leader alone, got %v", a)
	}
	if call("")["until"].(float64) != 0 {
		t.Error("the timer switches itself off after firing")
	}
	// a clock time already past today means tomorrow
	m = call("do=set&hour=0&minute=30&action=stop&who=all")
	if left := m["left"].(float64); left != 21*3600+59*60 {
		t.Errorf("00:30 when it's already later: tomorrow (2:31 -> 00:30 = 21h59m), got %v s", left)
	}
	if call("do=clear")["until"].(float64) != 0 {
		t.Error("cancel clears it")
	}
	if call("do=set&mins=99999")["until"].(float64) != 0 {
		t.Error("silly lengths are refused")
	}
}
