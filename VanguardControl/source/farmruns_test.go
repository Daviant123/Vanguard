package main

import (
	"encoding/json"
	"net"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

func TestFarmRuns(t *testing.T) {
	os.Remove(farmRunPath())
	defer os.Remove(farmRunPath())
	h := testHub(t)
	conn, _ := fakeChar(t, h, "CharB", "PLD", nil)
	m, _ := json.Marshal(map[string]any{"type": "farmrun", "name": "CharB", "zone": "West Ronfaure", "mobs": "Apex Bat",
		"secs": 2700, "kills": 57, "xp": 0, "cp": 41000, "loot": "12 Bat Wing", "why": "45 minutes done", "trial": "Apex Bat +57 (157/200)"})
	conn.WriteToUDP(m, h.conn.LocalAddr().(*net.UDPAddr))
	time.Sleep(200 * time.Millisecond)
	rec := httptest.NewRecorder()
	h.handleFarmRuns(rec, httptest.NewRequest("GET", "/api/farmruns", nil))
	var list []farmRun
	json.Unmarshal(rec.Body.Bytes(), &list)
	if len(list) != 1 || list[0].Kills != 57 || list[0].CP != 41000 || list[0].Why != "45 minutes done" || list[0].Zone != "West Ronfaure" || list[0].Trial != "Apex Bat +57 (157/200)" {
		t.Fatalf("the run is kept with its numbers, got %+v", list)
	}
	rec = httptest.NewRecorder()
	h.handleFarmRuns(rec, httptest.NewRequest("GET", "/api/farmruns?do=clear", nil))
	json.Unmarshal(rec.Body.Bytes(), &list)
	if len(list) != 0 {
		t.Error("clear empties the history")
	}
}

// The × on one run in Past runs takes just that run out of the history.
func TestFarmRunDelete(t *testing.T) {
	os.Remove(farmRunPath())
	defer os.Remove(farmRunPath())
	os.WriteFile(farmRunPath(), []byte(`[{"time":"2026-10-18 07:20","who":"CharA","zone":"Tahrongi Canyon","kills":66},
		{"time":"2026-10-18 05:14","who":"CharA","zone":"Mhaura","kills":38}]`), 0o644)
	h := testHub(t)
	rec := httptest.NewRecorder()
	h.handleFarmRuns(rec, httptest.NewRequest("GET", "/api/farmruns?do=del&time=2026-10-18+07%3A20&who=CharA", nil))
	var list []farmRun
	json.Unmarshal(rec.Body.Bytes(), &list)
	if len(list) != 1 || list[0].Zone != "Mhaura" {
		t.Fatalf("only the 07:20 run is taken out, got %+v", list)
	}
}
