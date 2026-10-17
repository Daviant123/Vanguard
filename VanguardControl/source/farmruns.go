// Past farming runs (farming upgrade 2). When a run ends the addon sends its summary ("farmrun": who, zone, time,
// kills, XP / CP, top loot, why it stopped); the app keeps the last 50 in farmruns.json next to the exe and shows them
// on the Farming tab - the run log paid script clients (DreamBot / OSBot) keep.
package main

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type farmRun struct {
	Time  string `json:"time"`
	Who   string `json:"who"`
	Zone  string `json:"zone"`
	Mobs  string `json:"mobs"`
	Secs  int    `json:"secs"`
	Kills int    `json:"kills"`
	XP    int    `json:"xp"`
	CP    int    `json:"cp"`
	Loot  string `json:"loot"`
	Why   string `json:"why"`
}

var farmRunMu sync.Mutex

func farmRunPath() string {
	exe, _ := os.Executable()
	return filepath.Join(filepath.Dir(exe), "farmruns.json")
}

func loadFarmRuns() []farmRun {
	var list []farmRun
	if b, err := os.ReadFile(farmRunPath()); err == nil {
		json.Unmarshal(b, &list)
	}
	if list == nil {
		list = []farmRun{}
	}
	return list
}

func (h *hub) addFarmRun(msg map[string]any) {
	num := func(k string) int { f, _ := msg[k].(float64); return int(f) }
	str := func(k string) string { v, _ := msg[k].(string); return v }
	r := farmRun{Time: time.Now().Format("2006-01-02 15:04"), Who: str("name"), Zone: str("zone"), Mobs: str("mobs"),
		Secs: num("secs"), Kills: num("kills"), XP: num("xp"), CP: num("cp"), Loot: str("loot"), Why: str("why")}
	farmRunMu.Lock()
	defer farmRunMu.Unlock()
	list := append(loadFarmRuns(), r)
	if len(list) > 50 {
		list = list[len(list)-50:]
	}
	b, _ := json.MarshalIndent(list, "", "  ")
	os.WriteFile(farmRunPath(), b, 0o644)
	h.addLog("%s: farming run saved (%d kills in %d min)", r.Who, r.Kills, r.Secs/60)
}

func (h *hub) handleFarmRuns(w http.ResponseWriter, r *http.Request) {
	farmRunMu.Lock()
	if r.URL.Query().Get("do") == "clear" {
		os.WriteFile(farmRunPath(), []byte("[]"), 0o644)
	}
	list := loadFarmRuns()
	farmRunMu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(list)
}
