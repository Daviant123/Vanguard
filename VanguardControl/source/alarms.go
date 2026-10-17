// Alarms (series 3 round 5). Paid multibox tools (ISBoxer, MMOMinion, Rebot) warn you when a character needs you;
// Vanguard Control does it from the app itself, so it works while the window is minimized behind the game: a Windows
// sound, a red banner and the character's card flashing when a character is KO'd, low on HP or MP, asleep /
// petrified / charmed / terrorized / stunned, drops offline (disconnected or the game closed), stuck / not in the
// zone / not fighting (the addon's own alerts), or a problem is caught. Each kind can be switched off in
// App & updates > Alarms; settings are kept in alarms.json next to the exe.
package main

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type alarmConfig struct {
	On       bool `json:"on"`
	Sound    bool `json:"sound"`
	Ring     bool `json:"ring"` // keep ringing every 15 s until OK is clicked
	KO       bool `json:"ko"`
	HP       bool `json:"hp"`
	HPAt     int  `json:"hp_at"`
	MP       bool `json:"mp"`
	MPAt     int  `json:"mp_at"`
	Disabled bool `json:"disabled"`
	Offline  bool `json:"offline"`
	Alerts   bool `json:"alerts"`
	Problem  bool `json:"problem"`
	Farm     bool `json:"farm"` // farming stopped, or nothing to fight for 5 minutes
}

type alarm struct {
	Who  string `json:"who"`
	Kind string `json:"kind"`
	Text string `json:"text"`
	Time string `json:"time"`
}

type alarmSeen struct{ ko, hp, mp, dis, online bool }

var alarmMu sync.Mutex
var alarmCfg = defaultAlarms()
var alarmActive []alarm
var alarmPrev = map[string]*alarmSeen{}
var alarmQuietUntil time.Time // after a stop-timer logout or a Log out order: going offline is expected
var alarmLastRing time.Time

// The sound: Windows' warning sound (MessageBeep, no extra program). Tests replace it.
var playAlarm = func() {
	defer func() { recover() }()
	syscall.NewLazyDLL("user32.dll").NewProc("MessageBeep").Call(0x30)
}

func defaultAlarms() alarmConfig {
	return alarmConfig{On: true, Sound: true, KO: true, HP: false, HPAt: 30, MP: false, MPAt: 10, Disabled: true,
		Offline: true, Alerts: true, Problem: true, Farm: true}
}

func alarmPath() string {
	exe, _ := os.Executable()
	return filepath.Join(filepath.Dir(exe), "alarms.json")
}

func loadAlarms() {
	c := defaultAlarms()
	if b, err := os.ReadFile(alarmPath()); err == nil {
		json.Unmarshal(b, &c)
	}
	alarmMu.Lock()
	alarmCfg = c
	alarmMu.Unlock()
}

var disabledBuffs = map[string]string{"sleep": "asleep", "petrification": "petrified", "terror": "terrorized",
	"charm": "charmed", "stun": "stunned"}

// raise: called with alarmMu held.
func (h *hub) raiseAlarm(who, kind, text string) {
	alarmActive = append(alarmActive, alarm{Who: who, Kind: kind, Text: text, Time: time.Now().Format("15:04:05")})
	if len(alarmActive) > 20 {
		alarmActive = alarmActive[len(alarmActive)-20:]
	}
	if who != "" {
		h.addLog("ALARM %s: %s", who, text)
	} else {
		h.addLog("ALARM: %s", text)
	}
	if alarmCfg.Sound {
		alarmLastRing = time.Now()
		go playAlarm()
	}
}

// checkAlarms looks at every character's latest status; an alarm goes off when something starts (not again while
// it lasts). The first look at a character only learns how it is.
func (h *hub) checkAlarms() {
	type look struct {
		name               string
		online, ko, hp, mp bool
		hpp, mpp           int
		dis                string
	}
	alarmMu.Lock()
	cfg := alarmCfg
	alarmMu.Unlock()
	num := func(m map[string]any, k string) int { f, _ := m[k].(float64); return int(f) }
	var looks []look
	h.mu.Lock()
	for n, c := range h.chars {
		s := c.Snapshot
		l := look{name: n, online: !c.LastSeen.IsZero() && time.Since(c.LastSeen) < 5*time.Second}
		st, _ := s["status"].(string)
		l.ko = st == "Dead"
		l.hpp, l.mpp = num(s, "hpp"), num(s, "mpp")
		l.hp = !l.ko && l.hpp > 0 && l.hpp < cfg.HPAt
		_, hasMP := s["mp"]
		l.mp = !l.ko && hasMP && num(s, "mp") > 0 && l.mpp < cfg.MPAt
		if bl, ok := s["buffs"].([]any); ok {
			for _, b := range bl {
				if m, ok := b.(map[string]any); ok {
					if d, ok := disabledBuffs[strings.ToLower(strings.TrimSpace(func() string { v, _ := m["n"].(string); return v }()))]; ok {
						l.dis = d
					}
				}
			}
		}
		looks = append(looks, l)
	}
	h.mu.Unlock()
	alarmMu.Lock()
	defer alarmMu.Unlock()
	quiet := time.Now().Before(alarmQuietUntil)
	for _, l := range looks {
		p, known := alarmPrev[l.name]
		if !known {
			alarmPrev[l.name] = &alarmSeen{ko: l.ko, hp: l.hp, mp: l.mp, dis: l.dis != "", online: l.online}
			continue
		}
		if cfg.On {
			switch {
			case cfg.Offline && p.online && !l.online && !quiet:
				h.raiseAlarm(l.name, "offline", "went offline (disconnected, or the game closed)")
			case !l.online:
			case cfg.KO && l.ko && !p.ko:
				h.raiseAlarm(l.name, "ko", "KO'd!")
			case cfg.Disabled && l.dis != "" && !p.dis:
				h.raiseAlarm(l.name, "disabled", l.dis+"!")
			case cfg.HP && l.hp && !p.hp:
				h.raiseAlarm(l.name, "hp", "HP "+strconv.Itoa(l.hpp)+"%")
			case cfg.MP && l.mp && !p.mp:
				h.raiseAlarm(l.name, "mp", "MP "+strconv.Itoa(l.mpp)+"%")
			}
		}
		if l.online {
			p.ko, p.dis = l.ko, l.dis != ""
			// low HP / MP: armed again only once it has come back up a little (no ringing on every tick)
			p.hp = l.hp || (p.hp && l.hpp < cfg.HPAt+10)
			p.mp = l.mp || (p.mp && l.mpp < cfg.MPAt+10)
		}
		p.online = l.online
	}
	if cfg.On && cfg.Sound && cfg.Ring && len(alarmActive) > 0 && time.Since(alarmLastRing) >= 15*time.Second {
		alarmLastRing = time.Now()
		go playAlarm()
	}
}

// alarmFromLog: the addon's alerts ("ALERT 30 yalms behind you") and caught problems.
func (h *hub) alarmFromLog(who, text string) {
	alarmMu.Lock()
	defer alarmMu.Unlock()
	if !alarmCfg.On {
		return
	}
	// farming: it stopped (a goal reached, KO'd, full bags, zoned) or has had nothing to fight for 5 minutes
	if alarmCfg.Farm && (strings.HasPrefix(text, "Farming stopped: ") || strings.HasPrefix(text, "Farming: ")) {
		h.raiseAlarm(who, "farm", strings.TrimPrefix(text, "Farming stopped: "))
		return
	}
	if !strings.HasPrefix(text, "ALERT ") {
		return
	}
	t := strings.TrimPrefix(text, "ALERT ")
	// KO'd / HP / MP / disabled come from the status above; the alerts add stuck, not in zone and not fighting
	if alarmCfg.Alerts && (strings.Contains(t, "behind you") || strings.Contains(t, "not in your zone") || strings.Contains(t, "not fighting")) {
		h.raiseAlarm(who, "alert", t)
	}
}

func (h *hub) alarmProblem(where string) {
	alarmMu.Lock()
	defer alarmMu.Unlock()
	if alarmCfg.On && alarmCfg.Problem {
		h.raiseAlarm("", "problem", "a problem was caught ("+where+"): App & updates > Problems")
	}
}

func quietAlarms(d time.Duration) {
	alarmMu.Lock()
	alarmQuietUntil = time.Now().Add(d)
	alarmMu.Unlock()
}

func (h *hub) alarmLoop() {
	for {
		time.Sleep(2 * time.Second)
		h.checkAlarms()
	}
}

func (h *hub) handleAlarms(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	alarmMu.Lock()
	switch q.Get("do") {
	case "set":
		b, _ := json.Marshal(alarmCfg)
		m := map[string]any{}
		json.Unmarshal(b, &m)
		k, v := q.Get("k"), q.Get("v")
		if _, ok := m[k]; ok {
			if n, err := strconv.Atoi(v); err == nil && (k == "hp_at" || k == "mp_at") {
				if n < 5 {
					n = 5
				}
				if n > 90 {
					n = 90
				}
				m[k] = n
			} else if k != "hp_at" && k != "mp_at" {
				m[k] = v == "1" || v == "true" || v == "on"
			}
			b, _ = json.Marshal(m)
			json.Unmarshal(b, &alarmCfg)
			b, _ = json.MarshalIndent(alarmCfg, "", "  ")
			os.WriteFile(alarmPath(), b, 0o644)
		}
	case "ok":
		alarmActive = nil
	case "test":
		go playAlarm()
	}
	body, _ := json.Marshal(map[string]any{"cfg": alarmCfg, "active": append([]alarm{}, alarmActive...)})
	alarmMu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}
