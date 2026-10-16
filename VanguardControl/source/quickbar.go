// Quick buttons (series 2 round 2): ISBoxer-style click bar. Each button is built from menus in the app - who,
// what, on whom - kept in quickbar.json next to the exe, and pressing it sends that character a normal game
// command through the addon ("act <kind> <target> <name>").
package main

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

type quickButton struct {
	Label  string `json:"label"`
	Who    string `json:"who"`    // a character name, or "*" for everyone
	Kind   string `json:"kind"`   // ma ja ws item attack follow stop
	Name   string `json:"name"`   // spell / ability / weapon skill / item
	Target string `json:"target"` // bt t me leader or a party member's name
}

var quickMu sync.Mutex
var quickKinds = map[string]bool{"ma": true, "ja": true, "ws": true, "item": true, "attack": true, "follow": true, "stop": true}
var safeName = regexp.MustCompile(`^[A-Za-z0-9 '\-:.()+]{0,60}$`)
var safeWord = regexp.MustCompile(`^[A-Za-z*]{1,20}$`)

func quickPath() string {
	exe, _ := os.Executable()
	return filepath.Join(filepath.Dir(exe), "quickbar.json")
}

func loadQuick() []quickButton {
	var list []quickButton
	if b, err := os.ReadFile(quickPath()); err == nil {
		json.Unmarshal(b, &list)
	}
	if list == nil {
		list = []quickButton{}
	}
	return list
}

func saveQuick(list []quickButton) error {
	b, _ := json.MarshalIndent(list, "", "  ")
	return os.WriteFile(quickPath(), b, 0o644)
}

func (b quickButton) valid() bool {
	return quickKinds[b.Kind] && safeWord.MatchString(b.Who) && safeWord.MatchString(b.Target) &&
		safeName.MatchString(b.Name) && safeName.MatchString(b.Label) &&
		(b.Name != "" || b.Kind == "attack" || b.Kind == "follow" || b.Kind == "stop")
}

// command is what the addon is asked to do for this button.
func (b quickButton) command() string {
	return strings.TrimSpace("act " + b.Kind + " " + b.Target + " " + b.Name)
}

func (h *hub) handleQuick(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	quickMu.Lock()
	list := loadQuick()
	switch q.Get("do") {
	case "add":
		b := quickButton{Label: strings.TrimSpace(q.Get("label")), Who: q.Get("who"), Kind: q.Get("kind"),
			Name: strings.TrimSpace(q.Get("name")), Target: q.Get("target")}
		if b.Label == "" {
			b.Label = b.Name
		}
		if b.valid() && len(list) < 40 {
			list = append(list, b)
			saveQuick(list)
		} else {
			h.addLog("That quick button couldn't be added.")
		}
	case "delete", "left", "right":
		i, err := strconv.Atoi(q.Get("i"))
		if err == nil && i >= 0 && i < len(list) {
			switch q.Get("do") {
			case "delete":
				list = append(list[:i], list[i+1:]...)
			case "left":
				if i > 0 {
					list[i-1], list[i] = list[i], list[i-1]
				}
			case "right":
				if i < len(list)-1 {
					list[i+1], list[i] = list[i], list[i+1]
				}
			}
			saveQuick(list)
		}
	case "press":
		i, err := strconv.Atoi(q.Get("i"))
		if err == nil && i >= 0 && i < len(list) && list[i].valid() {
			b := list[i]
			sent := 0
			if b.Who == "*" {
				for _, n := range h.names() {
					if h.send(n, b.command()) {
						sent++
					}
				}
			} else if h.send(b.Who, b.command()) {
				sent = 1
			}
			who := b.Who
			if who == "*" {
				who = "everyone"
			}
			if sent == 0 {
				h.addLog("%s isn't connected: \"%s\" not sent.", who, b.Label)
			} else {
				h.addLog("-> %s: %s", who, b.Label)
			}
		}
	}
	quickMu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(list)
}
