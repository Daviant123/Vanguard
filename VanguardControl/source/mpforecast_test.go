package main

import (
	"encoding/json"
	"math"
	"strings"
	"testing"
	"time"
)

// App 2.1.0 (CurePlease audit Phase 4): "MP lasts ~N min" from the last minutes of a caster's MP.
func TestMPForecast(t *testing.T) {
	t0 := time.Now()
	feed := func(tr *mpTrack, job string, secs int, mp func(s int) float64, status string) float64 {
		var got float64
		for s := 0; s <= secs; s++ {
			got = tr.add(job, mp(s), status, t0.Add(time.Duration(s)*time.Second))
		}
		return got
	}
	// 1200 MP, spending 100 MP a minute steadily for 2 min: 1000 left -> ~10 min
	tr := &mpTrack{}
	if got := feed(tr, "WHM", 120, func(s int) float64 { return 1200 - float64(s)*100/60 }, "Engaged"); math.Abs(got-10) > 0.3 {
		t.Fatalf("steady 100 MP/min with 1000 MP: %.1f min, want ~10", got)
	}
	// casts in bursts (a Cure IV of 88 MP every 30 s) + Refresh 3 MP every 3 s (60 MP a minute): net ~116 MP/min
	tr = &mpTrack{}
	mp := 1500.0
	got := feed(tr, "WHM", 150, func(s int) float64 {
		if s > 0 && s%30 == 0 {
			mp -= 88 * 3 // three cures at once
		}
		if s > 0 && s%3 == 0 {
			mp += 3
		}
		return mp
	}, "Engaged")
	if got <= 0 || got > 12 {
		t.Fatalf("bursts minus Refresh: %.1f min (mp %.0f), want a few minutes", got, mp)
	}
	// under 45 s of history: nothing yet
	tr = &mpTrack{}
	if got := feed(tr, "WHM", 30, func(s int) float64 { return 1200 - float64(s)*10 }, "Engaged"); got != 0 {
		t.Fatalf("30 s of history is too little: %.1f", got)
	}
	// MP going up (resting) or flat: nothing to show
	tr = &mpTrack{}
	if got := feed(tr, "WHM", 120, func(s int) float64 { return 300 + float64(s)*5 }, "Resting"); got != 0 {
		t.Fatalf("resting: %.1f", got)
	}
	tr = &mpTrack{}
	if got := feed(tr, "WAR", 120, func(int) float64 { return 0 }, "Engaged"); got != 0 {
		t.Fatalf("no MP at all: %.1f", got)
	}
	// very slow spending (MP lasts hours): not shown
	tr = &mpTrack{}
	if got := feed(tr, "RDM", 120, func(s int) float64 { return 2000 - float64(s)/10 }, "Engaged"); got != 0 {
		t.Fatalf("3 MP/min is not spending: %.1f", got)
	}
	// a job change starts over
	tr = &mpTrack{}
	feed(tr, "WHM", 120, func(s int) float64 { return 1200 - float64(s)*2 }, "Engaged")
	if got := tr.add("BLM", 900, "Idle", t0.Add(121*time.Second)); got != 0 || len(tr.samples) != 1 {
		t.Fatalf("new job: history kept (%d samples, %.1f)", len(tr.samples), got)
	}
	// KO: nothing, history dropped
	if got := tr.add("BLM", 0, "Dead", t0.Add(122*time.Second)); got != 0 || len(tr.samples) != 0 {
		t.Fatalf("KO: %.1f, %d samples", got, len(tr.samples))
	}
	// only the last 3 minutes count: 10 min of heavy spending, then 3 min flat -> nothing
	tr = &mpTrack{}
	feed(tr, "WHM", 600, func(s int) float64 { return 3000 - float64(s)*4 }, "Engaged")
	for s := 601; s <= 790; s++ {
		got = tr.add("WHM", 600, "Engaged", t0.Add(time.Duration(s)*time.Second))
	}
	if got != 0 || len(tr.samples) > 182 {
		t.Fatalf("old spending still counted: %.1f (%d samples)", got, len(tr.samples))
	}
	// almost out: at least 0.1 (shown as "<1 min")
	if v := forecastMP([]mpSample{{t0, 500}, {t0.Add(time.Minute), 1}}); v != 0.1 {
		t.Fatalf("almost out: %.2f, want 0.1", v)
	}
}

// The state message feeds the forecast and the page gets it as mp_mins.
func TestMPForecastInState(t *testing.T) {
	h := testHub(t)
	now := time.Now()
	c := &character{}
	h.chars["CharA"] = c
	for s := 0; s <= 90; s++ {
		c.MPMins = c.mp.add("WHM99/SCH49", 1000-float64(s)*2, "Engaged", now.Add(time.Duration(s)*time.Second))
	}
	c.LastSeen = now.Add(90 * time.Second)
	b, _ := json.Marshal(h.chars)
	if !strings.Contains(string(b), `"mp_mins":`) || c.MPMins < 6 || c.MPMins > 9 {
		t.Fatalf("mp_mins not in the page's state: %s (%.1f)", b, c.MPMins)
	}
	b, _ = json.Marshal(&character{})
	if strings.Contains(string(b), "mp_mins") {
		t.Fatalf("no forecast: mp_mins left out: %s", b)
	}
}

// The page: four-colour HP bars, the MP forecast, the Game chat tab (read only, nothing typed into the game), and a
// menu for each new 1.3.0 setting (values: addons\Vanguard\tests\test_app_130.py runs the page with a real profile).
func TestPageHas210ChatMPHpMenus(t *testing.T) {
	b, err := webFS.ReadFile("web/index.html")
	if err != nil {
		t.Fatal(err)
	}
	page := string(b)
	for _, want := range []string{
		"--hp-ok:", "--hp-mid:", "--hp-low:", "--hp-crit:", "const hpColor = v =>",
		`bar(s.hpp, hpColor(s.hpp)`, `bar(ts.hpp, hpColor(ts.hpp)`,
		"function mpHint(c)", "MP lasts ~", "chars[n].mp_mins",
		`{id: "chat", label: "Game chat"}`, `fetch("/api/chat?since=" + chatSince)`, "Nothing is ever typed into the game",
		"set heal.priority_cover ", "set heal.curaga_on ", "set heal.predict true", "set heal.predict_lead ",
		"set heal.predict_cap ", "set heal.predict_window ", `"items.temp_mp"`, "set assist.hate_spell ", "set assist.hate_on ",
		"set ja.settle ", "set cast.tail ", "set wake.on true", "set cast.log_gap true",
	} {
		if !strings.Contains(page, want) {
			t.Errorf("the page has no %q", want)
		}
	}
	if strings.Contains(page, `bar(s.hpp, "var(--hp)"`) {
		t.Errorf("an HP bar is still one colour")
	}
	for _, bad := range []string{"/api/chat/send", "input /tell", "input /p "} {
		if strings.Contains(page, bad) {
			t.Errorf("the chat view must not type anything: found %q", bad)
		}
	}
}
