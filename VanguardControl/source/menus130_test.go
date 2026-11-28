package main

import (
	"strings"
	"testing"
)

// App 2.1.0 (addon 1.3.0, CurePlease audit 2.2 / 2.3 / 2.6 / 2.7): the page has a menu for each new White Mage,
// Geomancer and MP setting, sending the addon's own command (values: addons\Vanguard\tests\test_whm_geo_mana.py).
func TestPageHasMenusFor130WhmGeoMana(t *testing.T) {
	b, err := webFS.ReadFile("web/index.html")
	if err != nil {
		t.Fatalf("index.html missing: %v", err)
	}
	page := string(b)
	for _, want := range []string{
		"set whm.afflatus ",                                       // Job tab: Afflatus stance
		"set mana.devotion_to ", "set mana.devotion_engaged true", // Healing tab: Devotion
		"set mana.sub_skip_refresh true",  // Healing tab: Sublimation under Refresh
		`set("geo.indi_engaged", "true")`, // Job tab: Indi only in fights
	} {
		if !strings.Contains(page, want) {
			t.Errorf("the page has no menu sending %q", want)
		}
	}
}

// App 2.1.0 (addon 1.3.0, CurePlease audit 3.1): the party board shows "can't see X" from the snapshot's unseen list,
// and the Team tab redraws when it changes (values: addons\Vanguard\tests\test_cant_see.py).
func TestPageShowsCantSee(t *testing.T) {
	b, err := webFS.ReadFile("web/index.html")
	if err != nil {
		t.Fatalf("index.html missing: %v", err)
	}
	page := string(b)
	for _, want := range []string{
		"function unseenHint(s)", "arr(s.unseen)", "can't see ${", "${unseenHint(s)}",
		"(chars[n].snapshot || {}).unseen]",
	} {
		if !strings.Contains(page, want) {
			t.Errorf("the page has no %q", want)
		}
	}
}
