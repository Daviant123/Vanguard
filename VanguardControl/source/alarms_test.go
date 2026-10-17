package main

import (
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestAlarms(t *testing.T) {
	os.Remove(alarmPath())
	defer os.Remove(alarmPath())
	loadAlarms()
	var rings int32
	playAlarm = func() { atomic.AddInt32(&rings, 1) }
	alarmMu.Lock()
	alarmPrev, alarmActive, alarmQuietUntil = map[string]*alarmSeen{}, nil, time.Time{}
	alarmMu.Unlock()
	h := testHub(t)
	set := func(name string, snap map[string]any) {
		h.mu.Lock()
		c, ok := h.chars[name]
		if !ok {
			c = &character{}
			h.chars[name] = c
		}
		c.Snapshot, c.LastSeen = snap, time.Now()
		h.mu.Unlock()
	}
	active := func() []alarm {
		alarmMu.Lock()
		defer alarmMu.Unlock()
		return append([]alarm{}, alarmActive...)
	}
	call := func(q string) { h.handleAlarms(httptest.NewRecorder(), httptest.NewRequest("GET", "/api/alarms?"+q, nil)) }

	set("CharB", map[string]any{"status": "Engaged", "hpp": 80.0, "mpp": 50.0, "mp": 500.0})
	h.checkAlarms() // first look: only learns
	if len(active()) != 0 {
		t.Fatal("the first look at a character never rings")
	}
	set("CharB", map[string]any{"status": "Dead", "hpp": 0.0, "mpp": 50.0, "mp": 500.0})
	h.checkAlarms()
	h.checkAlarms()
	a := active()
	if len(a) != 1 || a[0].Kind != "ko" || a[0].Who != "CharB" {
		t.Fatalf("KO'd rings once (not on every look), got %+v", a)
	}
	time.Sleep(50 * time.Millisecond)
	if atomic.LoadInt32(&rings) != 1 {
		t.Errorf("one sound, got %d", rings)
	}
	call("do=ok")
	if len(active()) != 0 {
		t.Error("OK clears the alarms")
	}
	// asleep, from the party buffs
	set("CharB", map[string]any{"status": "Engaged", "hpp": 60.0, "mpp": 50.0, "mp": 500.0, "buffs": []any{map[string]any{"n": "Sleep", "b": true}}})
	h.checkAlarms()
	if a := active(); len(a) != 1 || a[0].Text != "asleep!" {
		t.Errorf("asleep rings, got %+v", a)
	}
	call("do=ok")
	// low HP is off by default; switched on (and the setting saved) it rings once, again only after recovering
	set("CharB", map[string]any{"status": "Engaged", "hpp": 20.0, "mpp": 50.0, "mp": 500.0})
	h.checkAlarms()
	if len(active()) != 0 {
		t.Error("low HP is off until ticked")
	}
	call("do=set&k=hp&v=1")
	call("do=set&k=hp_at&v=40")
	if b, _ := os.ReadFile(alarmPath()); !strings.Contains(string(b), `"hp_at": 40`) || !strings.Contains(string(b), `"hp": true`) {
		t.Errorf("settings are saved: %s", b)
	}
	set("CharB", map[string]any{"status": "Engaged", "hpp": 79.0, "mpp": 50.0, "mp": 500.0})
	h.checkAlarms()
	set("CharB", map[string]any{"status": "Engaged", "hpp": 35.0, "mpp": 50.0, "mp": 500.0})
	h.checkAlarms()
	set("CharB", map[string]any{"status": "Engaged", "hpp": 41.0, "mpp": 50.0, "mp": 500.0})
	h.checkAlarms()
	set("CharB", map[string]any{"status": "Engaged", "hpp": 33.0, "mpp": 50.0, "mp": 500.0})
	h.checkAlarms()
	if a := active(); len(a) != 1 || a[0].Text != "HP 35%" {
		t.Errorf("HP under 40%% rings once; bobbing around 40 doesn't ring again: %+v", a)
	}
	call("do=ok")
	// the addon's alerts: stuck and not in zone ring; KO'd from the alert doesn't double up
	h.alarmFromLog("CharB", "ALERT 34 yalms behind you")
	h.alarmFromLog("CharB", "ALERT KO'd!")
	h.alarmFromLog("CharB", "Cure IV -> CharA")
	if a := active(); len(a) != 1 || a[0].Kind != "alert" {
		t.Errorf("stuck behind rings, the rest don't: %+v", a)
	}
	call("do=ok")
	// farming
	h.alarmFromLog("CharB", "Farming stopped: 12 Beastmen's Seal in the bags")
	h.alarmFromLog("CharB", "Farming: nothing to fight for 5 minutes")
	h.alarmFromLog("CharB", "Farming started")
	h.alarmFromLog("CharB", "Farming key: CTRL+F9")
	h.alarmFromLog("CharB", "Farming: got Kindred's Crest!")
	if a := active(); len(a) != 3 || a[0].Kind != "farm" || a[0].Text != "12 Beastmen's Seal in the bags" || a[2].Text != "Farming: got Kindred's Crest!" {
		t.Errorf("farming stopped / idle ring, starting doesn't: %+v", a)
	}
	call("do=ok")
	// went offline: rings; but not after a Log out order
	h.mu.Lock()
	h.chars["CharB"].LastSeen = time.Now().Add(-10 * time.Second)
	h.mu.Unlock()
	h.checkAlarms()
	if a := active(); len(a) != 1 || a[0].Kind != "offline" {
		t.Errorf("a character dropping offline rings: %+v", a)
	}
	call("do=ok")
	set("CharB", map[string]any{"status": "Idle", "hpp": 100.0})
	h.checkAlarms()
	quietAlarms(time.Minute)
	h.mu.Lock()
	h.chars["CharB"].LastSeen = time.Now().Add(-10 * time.Second)
	h.mu.Unlock()
	h.checkAlarms()
	if len(active()) != 0 {
		t.Error("logging out on purpose doesn't ring")
	}
	// everything off
	call("do=set&k=on&v=0")
	set("CharB", map[string]any{"status": "Dead", "hpp": 0.0})
	h.checkAlarms()
	h.checkAlarms()
	if len(active()) != 0 {
		t.Error("Alarms off: nothing rings")
	}
}
