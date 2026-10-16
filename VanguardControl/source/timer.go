// Stop timer (series 2 round 4). Paid script clients (DreamBot, OSBot, TriBot) let you stop after a set run time;
// Vanguard Control does it for the whole team: stop after N minutes or at a clock time, then either just stop
// everyone or stop and log out (the normal /logout command). It runs in the app, so it works with the window closed
// to the tray or minimized.
package main

import (
	"encoding/json"
	"net/http"
	"strconv"
	"sync"
	"time"
)

type stopTimer struct {
	Until  int64  `json:"until"`  // unix seconds, 0 = off
	Action string `json:"action"` // stop | logout
	Who    string `json:"who"`    // all | alts (everyone but the leader)
}

var timerMu sync.Mutex
var timerNow = time.Now // tests move the clock

// leaderName: the character the others follow (the one named most often as leader).
func (h *hub) leaderName() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	count := map[string]int{}
	for _, c := range h.chars {
		if l, _ := c.Snapshot["leader"].(string); l != "" {
			count[l]++
		}
	}
	best, n := "", 0
	for l, k := range count {
		if k > n || (k == n && l < best) {
			best, n = l, k
		}
	}
	return best
}

// fireTimer: time's up - stop (and log out) the chosen characters.
func (h *hub) fireTimer(t stopTimer) {
	leader := h.leaderName()
	n := 0
	for _, name := range h.names() {
		if t.Who == "alts" && name == leader {
			continue
		}
		h.send(name, "off")
		if t.Action == "logout" {
			quietAlarms(3 * time.Minute)
			h.send(name, "logout")
		}
		n++
	}
	what := "stopped"
	if t.Action == "logout" {
		what = "stopped and logging out"
	}
	h.addLog("Stop timer: time's up - %d character(s) %s.", n, what)
}

func (h *hub) timerLoop() {
	for {
		time.Sleep(5 * time.Second)
		h.checkTimer()
	}
}

func (h *hub) checkTimer() {
	timerMu.Lock()
	t := h.timer
	due := t.Until > 0 && timerNow().Unix() >= t.Until
	if due {
		h.timer = stopTimer{}
	}
	timerMu.Unlock()
	if due {
		h.fireTimer(t)
	}
}

func (h *hub) handleTimer(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	timerMu.Lock()
	switch q.Get("do") {
	case "set":
		action, who := q.Get("action"), q.Get("who")
		if action != "logout" {
			action = "stop"
		}
		if who != "alts" {
			who = "all"
		}
		var until time.Time
		now := timerNow()
		if mins, err := strconv.Atoi(q.Get("mins")); err == nil && mins > 0 && mins <= 24*60 {
			until = now.Add(time.Duration(mins) * time.Minute)
		} else if hour, err := strconv.Atoi(q.Get("hour")); err == nil && hour >= 0 && hour < 24 {
			minute, _ := strconv.Atoi(q.Get("minute"))
			until = time.Date(now.Year(), now.Month(), now.Day(), hour, minute%60, 0, 0, now.Location())
			if !until.After(now) {
				until = until.Add(24 * time.Hour) // that time tomorrow
			}
		}
		if !until.IsZero() {
			h.timer = stopTimer{Until: until.Unix(), Action: action, Who: who}
			h.addLog("Stop timer set: %s at %s.", map[string]string{"stop": "stop", "logout": "stop and log out"}[action], until.Format("15:04"))
		}
	case "clear":
		if h.timer.Until > 0 {
			h.addLog("Stop timer cancelled.")
		}
		h.timer = stopTimer{}
	}
	t := h.timer
	timerMu.Unlock()
	left := int64(0)
	if t.Until > 0 {
		left = t.Until - timerNow().Unix()
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"until": t.Until, "action": t.Action, "who": t.Who, "left": left})
}
