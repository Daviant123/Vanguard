package main

import (
	"strings"
	"testing"
)

// App 2.0.0: the page built into the exe has a menu for every setting added in Vanguard 1.2.0, each sending the
// addon's own command (the values themselves are checked against the real addon in
// addons\Vanguard\tests\test_app_menus_120.py, which runs this page in Node.js).
func TestPageHasMenusFor120Settings(t *testing.T) {
	b, err := webFS.ReadFile("web/index.html")
	if err != nil {
		t.Fatalf("index.html missing: %v", err)
	}
	page := string(b)
	for _, want := range []string{
		"set follow.move_tick ",                          // Job tab: movement speed
		"set assist.resync true", "set assist.seek true", // Job tab: more fighting options
		"set assist.seek_range ", "set assist.max_mobs ", "set assist.seek_unclaimed true",
		"set assist.on_engage ",                                // On each new mob, first use
		"scf set ${i + 1}", `"scf on"`, "set scf.tune_sc true", // Skillchains tab
		"scfLearnedLine(",                                       // ...the learned-timing line
		`"enfeebler on"`, "enfeebler count ", "enfeebler mobs ", // Enfeebles tab: Enfeebler mode
		"enfeebler pull on", "enfeebler range ", "enfeebler stay on", "enfeebler spells ", "set enfeebler.wait_hp ",
		"set cor.quickdraw ", "set rng.hover_step true", "set hud.tp true", // job extras, display
		"gained ${esc(m.buff)}",            // enemy watch: the buff it gained
		`id="planbox"`, "/api/planner?on=", // the team planner switch (Team tab)
	} {
		if !strings.Contains(page, want) {
			t.Errorf("the page has no menu sending %q", want)
		}
	}
}
