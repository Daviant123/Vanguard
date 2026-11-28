// MP forecast (2.1.0, CurePlease audit Phase 4): "MP lasts ~N min" for each caster, from its own MP over the last
// few minutes (the MP in every state message). Only the app works it out; nothing is sent back to the game.
//
// The pace is the MP used minus the MP gained (Refresh, Convert, Sublimation, resting) over the last mpWindow. With
// under mpMinSpan of history, a pace under mpMinRate MP a minute, or MP lasting more than mpMaxMins, nothing is shown.
package main

import (
	"math"
	"time"
)

const (
	mpWindow  = 3 * time.Minute
	mpMinSpan = 45 * time.Second
	mpMinRate = 5.0   // MP a minute: slower than this counts as not spending
	mpMaxMins = 120.0 // longer than this: plenty, not shown
	mpEvery   = time.Second
)

type mpSample struct {
	t  time.Time
	mp float64
}

type mpTrack struct {
	job     string
	samples []mpSample
}

// add records the character's MP now and returns the forecast in minutes (0 = nothing to show).
// A new job or being KO'd starts the history over.
func (tr *mpTrack) add(job string, mp float64, status string, now time.Time) float64 {
	if job != tr.job || status == "Dead" {
		tr.job, tr.samples = job, nil
		if status == "Dead" {
			return 0
		}
	}
	if n := len(tr.samples); n > 0 && now.Sub(tr.samples[n-1].t) < mpEvery {
		tr.samples[n-1].mp = mp // (state comes several times a second: one sample a second is enough)
	} else {
		tr.samples = append(tr.samples, mpSample{now, mp})
	}
	cut := 0
	for cut < len(tr.samples) && now.Sub(tr.samples[cut].t) > mpWindow {
		cut++
	}
	tr.samples = tr.samples[cut:]
	return forecastMP(tr.samples)
}

// forecastMP: minutes until MP runs out at the pace of these samples (oldest first), rounded to 0.1; 0 = none.
func forecastMP(s []mpSample) float64 {
	if len(s) < 2 {
		return 0
	}
	span := s[len(s)-1].t.Sub(s[0].t)
	if span < mpMinSpan {
		return 0
	}
	spent, gained := 0.0, 0.0
	for i := 1; i < len(s); i++ {
		if d := s[i].mp - s[i-1].mp; d < 0 {
			spent -= d
		} else {
			gained += d
		}
	}
	rate := (spent - gained) / span.Minutes()
	if rate < mpMinRate {
		return 0
	}
	mins := s[len(s)-1].mp / rate
	if mins > mpMaxMins {
		return 0
	}
	return math.Max(0.1, math.Round(mins*10)/10)
}
