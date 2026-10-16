# Vanguard

A multibox party assistant for Final Fantasy XI (Windower 4): your other characters follow, assist, heal, buff,
sing, roll, bubble and enfeeble on their own, and you run them all from one desktop app, **Vanguard Control**.

> Automation tools break Square Enix's terms of service and can get accounts banned. Supervise your characters;
> don't leave them running unattended.

## Install (the app does it)

1. Download this page (green **Code** button > **Download ZIP**) and unzip it. Open the **VanguardControl** folder and
   run `Vanguard Control.exe` (Windows may warn about an unknown app the first time: More info > Run anyway).
2. The app finds your Windower folder (or asks you to pick it), installs the Vanguard addon into
   `Windower\addons\Vanguard` and sets it to load when the game starts.
3. Start the game (or, if it's already running, type `//lua load vanguard` once in each game window). Your characters
   appear in the app: click the one you play, **Set up party**, **Start all**.

## Updates (automatic)

The app checks this page when it starts and every 6 hours. A newer version downloads by itself, restarts the app,
updates the addon and reloads it on your characters. Your settings are never touched. To turn it off, put an empty
file named `noupdate.txt` next to the exe (you can still use **Check for updates** in the app).
Without the app: copy the **Vanguard** folder into `Windower\addons\`; `//vg update install` updates it.

## What it sends to the game

Only normal commands, the same ones you could type: `/ma`, `/ja`, `/ws`, `/ra`, `/attack`, `/pcmd`, `/mount`,
`/heal` and so on, plus walking (Windower's run, like the follow addons). No packets are injected. The characters
talk to each other and to the app only on your own PC (Windower's IPC and a local UDP port, 127.0.0.1:47000).

---

## Setup (once)

Run **Vanguard Control**; it installs the addon (see Install above).

## Every session: 3 clicks

1. Log in your characters.
2. In Vanguard Control, click the character you play, then **Set up party**.
   That character leads. Everyone else follows, assists, and loads the recommended setup for their job.
3. Press **Start all**.

## How job setup works

Vanguard knows all 22 jobs. When a character logs in or changes job, it picks a **role** for that job
(e.g. WHM → Healer, WAR → Melee DD, PLD → Tank, BRD → Support, BLM → Nuker, BST → Pet) and turns on what that
role needs: modules, weapon skill, songs, geo bubbles, enfeebles, and the job's abilities.

Select a character in the panel to see:

- **Role**: pick another role and the whole setup changes to match (e.g. RDM: Support, Nuker, Melee DD).
- **Weapon skill**: chosen from the weapon skills the character knows right now.
- **Follow / assist**: who this character follows.
- **Abilities**: grouped as Buffs, Offense, Defense, Healing, Support, Debuffs, Pet and Recovery. Only
  abilities the character can use right now appear, including sub-job ones (SAM sub shows Hasso and Meditate).
  Untick anything you don't want; it's remembered per job.
- **Reset to recommended**: back to the default for that job and role.

Abilities are used with sensible rules: buffs only when missing, two-hours and big cooldowns only in a fight,
WAR uses Warrior's Charge before its WS, COR rolls and Double-Ups toward lucky numbers, NIN keeps Utsusemi up,
pet jobs call or summon their pet when it's missing, and so on.

## Point-and-click menus (CurePlease style)

Click a character on the left, then use the tabs. Each tab only appears if that character can use it, and
only lists spells it can cast right now (main job + sub job, highest tier known):

| Tab | What you tick |
|---|---|
| Job & abilities | Role, weapon skill, who to follow, and the job's abilities |
| Healing | Cure / Raise / Remove status effects / Wake sleeping / Use Curaga; sliders for when to cure; per member "Heal & cleanse" and "Priority"; which status effects to remove |
| Buffs | A grid: each buff spell × each party member. Tick who gets Haste, Refresh, Protect, etc. Plus self buffs |
| Enfeebles | Which enfeebles to land on each new mob, retry count, Dispel |
| Songs | Song 1–5 dropdowns, always or only during fights |
| Geomancy | Indi, Geo, where the luopan goes, Entrust spell and member |
| Advanced | Raw module switches, farm route recording, command box |

Everything you tick is saved **per job** and comes back the next time that character is on that job.
**Reset to recommended** clears your ticks for the current job.

The same menus work from chat: `//vg menu buff CharA on Haste II`, `//vg menu song 1 Honor March`,
`//vg menu debuff on Slow II`, `//vg menu indi Indi-Fury`, `//vg menu heal CharA off`,
`//vg menu priority CharA on`, `//vg menu cleanse off poison`.

## Playing alts (new in 0.2.0)

These are on by default and survive presets:

- **Alerts on your main's screen.** Each alt tells the character it follows when it is **KO'd**, **low on HP**
  (under 30%), **out of MP** (under 10%), **stuck far behind** (30+ yalms for 10 s) or **not in your zone**, or
  **standing idle while you fight** (15 s). They show in red in your chat; repeats wait a minute.
  `//vg alerts on|off`, `//vg set alerts.hp 30`, `alerts.mp`, `alerts.far`, `alerts.idle`, `alerts.repeat`,
  and `//vg set alerts.sound C:\path\ding.wav` for a sound.
- **Mount sync.** When your main mounts, the alts mount (Raptor by default); when it dismounts, they do.
  Never during a fight. `//vg mountsync on|off`, `//vg set mount.name Chocobo`.
- **Food & Reraise upkeep.** Between fights, re-eat food and keep Reraise up.
  `//vg food Grape Daifuku` (`off` to stop), `//vg reraise auto` (best Reraise spell the job knows),
  `//vg reraise Instant Reraise` (an item or a named spell), `//vg reraise off`.

## Party, formation, hold and camp (new in 0.3.0)

- **`//vg party`** on your main invites every character running Vanguard that isn't in the party yet. The alts accept
  by themselves when the invite comes from their leader or another Vanguard character (`//vg party accept off` to stop).
- **Formation**: alts stand in a fan behind you (`spread`, the default) instead of on top of you, so they're easy to
  see and take fewer area attacks. `//vg formation line` for single file, `//vg formation off` for plain follow.
- **`//vg hold`** on your main: the alts stop where they are and don't run off to fight. **`//vg come`**: they follow
  and assist again.
- **`//vg camp`** on your main: the alts come back to that spot after every fight (in formation) and wait there; they
  still join your fights. `//vg camp off` to follow again.
- Alerts now also tell you when an alt is **asleep, petrified, terrorized, charmed** or stunned for a while.

## Trail follow, alt overview, pull to camp (new in 0.4.0)

- **Trail & zone follow.** When an alt falls behind, it follows the path you actually walked (around corners instead
  of into the wall), and when you zone it runs the rest of your path and through the zone line after you.
  `//vg set follow.trail false` for straight-line following.
- **Alt overview box** on your main's screen: every alt's job, HP, MP, TP, distance and what it's doing, red when
  something's wrong, grey "(no word)" if an alt goes quiet. Drag it where you like. `//vg hud off` to hide it.
- **Pull to camp.** Farming with a camp: set `//vg camp` where you want to fight and a pull command
  (`//vg set farm.pull_cmd input /ra <t>` or `input /ma "Dia" <t>`). The farmer pulls first (before buffing),
  runs back to camp and fights the mob there; the alts wait at camp.

## Travel, resting and retreat (new in 0.5.0)

- **Sneak & Invisible sync.** When you go sneaked / invisible, each alt does the same on itself: Spectral Jig if it's
  a DNC (main or sub), its own Sneak / Invisible spell if it has one, otherwise a Silent Oil / Prism Powder from its
  inventory (it tells you if it has nothing). `//vg stealth off` to stop.
- **Rest sync.** When you `/heal`, alts that aren't full rest too once they've reached you; when you stand up, the
  ones that sat down with you stand up. `//vg restsync off` to stop.
- **`//vg retreat`** on your main: every alt stops fighting (`/attackoff`), runs back to you (or to camp) and holds.
  `//vg come` when it's safe.

## Fighting with the leader, hotkeys (new in 0.6.0)

- **Disengage with you.** When you stop attacking, alts that were assisting stop 2 seconds later (a quick re-target
  doesn't count), and BST / SMN / PUP call their pets back. If you're KO'd they keep fighting.
  `//vg set assist.disengage false` to turn it off.
- **Self-defense.** A mob attacking an alt while you're not fighting: melee alts fight back; casters tell you
  they're being attacked. `//vg set assist.defend false` to turn it off.
- **Hotkeys** on your main: `//vg keys on`, then
  Ctrl+F1 hold / come, Ctrl+F2 retreat, Ctrl+F3 camp here / camp off, Ctrl+F4 invite the alts,
  Ctrl+F5 start / stop everyone, Ctrl+F6 show / hide the alt box, Ctrl+F7 alts' defense set on / off. `//vg keys off` removes them.

## Team setups, XP party, next target (new in 0.7.0)

- **Team setups.** `//vg setup save Odyssey` on your main: every character saves its current setup (its job's role,
  weapon skill, abilities and menus, plus leader, formation, food, Reraise, mount, farm targets) under that name.
  `//vg setup load Odyssey` puts everyone back. A character on another job gets it when it changes to that job.
  `//vg setup list`, `//vg setup delete <name>`.
- **XP / CP / EP party in one command.** `//vg exp Locus Wivre, Locus Dire Bat` on your main: you pull (with your
  `farm.pull_cmd` if set) to a camp at your spot, the alts assist and fight at camp. `//vg exp off` to stop
  (`//vg cp` / `//vg ep` do the same).
- **Next target.** After a kill, if another monster is still attacking someone in the party and you aren't fighting,
  melee alts take it on. `//vg set assist.autotarget false` to turn it off.

## Characters working together, sending commands (new in 0.8.0)

- **Shared enfeebles.** When one character casts an enfeeble on a mob the others wait; once it lands, nobody casts it
  on that mob again; if it's resisted, another may try. No more two characters both casting Slow.
- **Healer teamwork.** A healer starting a cure tells the other healers, who leave that member to it for the cast
  time (a Curaga covers everyone), unless the member drops under 35% (`//vg set share.emergency 35`).
- **`//vg send <command>`** runs a command on every other character: `//vg send /ma "Haste" CharA`,
  `//vg send warp`. `//vg sendall` includes this character, `//vg sendto CharB <command>` just one.
  Commands starting with `/` are typed into the game; anything else is a Windower / addon command.

## Gear modes, getting unstuck, away safety (new in 0.9.0)

- **GearSwap sync.** `//vg defense physical|magical|off` on your main switches every alt's GearSwap defense mode
  (standard Mote files; `//vg set gear.physical <gs command>` if a file uses other names). Ctrl+F7 toggles it with
  `//vg keys on`. `//vg gs <command>` sends any GearSwap command, e.g. `//vg gs cycle OffenseMode`.
  `//vg set gear.auto true`: an alt under 40% HP in a fight puts its defense set on until it's back over 75%.
- **Stuck recovery.** An alt running but not moving for 2 seconds steps sideways for a moment and tries again; after
  3 tries it tells you it's stuck.
- **Away safety.** If you haven't moved or fought for 20 minutes, the alts pause themselves and tell you; they carry
  on as soon as you move. `//vg set away.minutes 30` to change it, `0` to turn it off.

Settings are now saved safely with several characters running (one character's save no longer undoes another's).

## White Mage, Red Mage, Scholar (new in 0.10.0, from the community job guides)

- **One -na for the party.** When 2+ members have the same ailment, a White Mage uses Divine Seal (a Scholar in
  Light Arts: Accession) first, so one Poisona / Paralyna / ... clears everyone.
- **Bar spells.** `//vg bar fire` (ice, wind, earth, thunder, water) on your main: every alt that can keeps the
  Bar-element and its matching Bar-status up (fire + amnesia, ice + paralyze, wind + silence, earth + petrify,
  water + poison). Name another status if you like: `//vg bar wind sleep`. `//vg bar off` to stop.
  White Mages cast the party versions (Barfira ...), Red Mages / Scholars their own.
- **Paladin in the party:** the White Mage skips Protectra (Majesty is better).
- **Red Mage:** Saboteur right before the first Dia / Distract / Frazzle on a new mob; when Frazzle or Distract is
  resisted, Stymie so the next one lands.
- **Sleep extra mobs.** `//vg sleep on`: a second mob attacking the party (not the one you're fighting) gets
  Sleep II / Sleep / Foe Lullaby / Sleepga. It's slept again when it wakes up; undead and mobs it doesn't work on
  are left alone, and two characters never sleep the same mob.
- **Scholar stratagems.** As healer: Accession + Regen when 3+ members nearby have no Regen, Perpetuance + Regen V
  on you, and Aurorastorm II on itself. As nuker: makes its own skillchain with Immanence (Stone then Fire II =
  Liquefaction) and the burst module bursts on it. `//vg chain fusion` (liquefaction, scission, reverberation,
  detonation) to pick another, `//vg chain off` to stop.
- Settings: `//vg set mages.<name> <value>` (aoe_na, saboteur, stymie, accession, perpetuance, chain_every,
  strat_secs = seconds per stratagem charge, 33 with 550 Job Points).

## Corsair, Geomancer, Bard (new in 0.11.0, from the community job guides)

- **Smarter Double-Up.** The Corsair stops on the lucky number or 11. It uses Snake Eye at 10 (for 11), one short of
  lucky, or to get off the unlucky number, and Folds a bust. Otherwise it only Doubles-Up when it can't bust
  (5 or less). For more risk: `//vg set cor.risk 17` (also Double-Up on 6), `33` (on 7) ...
  (Fixed: the old Double-Up mistook each roll's unlucky number for a lucky one.)
- **Roll range.** Rolls only reach people within 8 yalms, so the Corsair walks over to you before rolling.
  With Luzaf's Ring: `//vg set cor.range 16`.
- **Roll sets.** `//vg rolls melee` (Samurai + Chaos), `magic` (Wizard's + Warlock's), `accuracy`, `tank`, `crit`,
  `refresh`, `exp`, `fastcast`, or name two: `//vg rolls chaos,rogue's`. Typed on CharA it goes to the Corsair alt.
- **Geomancer.** Casts Dia II first so Geo-Frailty / Malaise work (the guide: the GEO must be on the mob's hate list).
  `//vg set geo.entrust auto` entrusts Indi-Haste (or Indi-Fury) to you. Radial Arcana also when 2+ party members are
  under 40% MP (`geo.party_mp`).
- **Bard NiTro.** In a fight with songs due: Nightingale + Troubadour + Marcato, then all songs fresh (they last twice
  as long; it knows). `//vg set songs.nitro false` to save them for yourself.
- **Pianissimo songs.** `//vg pianissimo Mage's Ballad III > CharB|CharC` sings Ballad to just those two;
  add more lines (e.g. `Sentinel's Scherzo > CharA`). `//vg pianissimo` shows them, `//vg pianissimo clear` empties.
  Got a Terpander / Daurdabla? Just put 3 or 4 songs in the song list.
- **Horde Lullaby.** With `//vg sleep on`, two or more extra mobs get Horde Lullaby (or Sleepga) at once.

## Quick buttons (new in 0.20.0 / Vanguard Control 1.9.0)

On the Team tab, build a button from menus: **who** (a character or everyone), **does** (a spell, ability, weapon
skill, item, attack, follow or stop), **which** one (only what that character can use) and **on** whom. Buttons sit
in a bar under the top buttons on every tab; one click makes that character do it.

## Session stats and What's new (new in 0.19.0 / Vanguard Control 1.8.0)

- **Session** box on the Team tab: for every character, experience, Capacity Points and limit points per hour,
  kills, deaths and time, counted from its own game messages. **Reset** starts a new session (`//vg stats reset`).
- **What's new** tab: what each update added or fixed, in plain words.

## Scholar stratagems, main job and /SCH (new in 0.15.0 / Vanguard Control 1.4.0)

The **Stratagems** tab appears for any character with Scholar as main or sub job.
- **Charges** are worked out from the Scholar level: SCH 99 has 5 (one back every 48 s, 33 s with the 550 Job Point
  gift), /SCH at 49 has 2 (one every 2 minutes). The tab shows how many are ready.
- **Keep Arts up:** Light Arts (Dark Arts for nukers), or pick one; stratagems need it.
- **Which spells get which stratagem:** a list per stratagem, plus thresholds:
  Perpetuance (enhancing buffs that should last longer), Accession (party buffs when enough members need them, and a
  Scholar's Curaga: Accession + Cure when several are hurt), Celerity (Raise spells, emergency cures), Penury (when
  MP is low), Rapture (emergency cures), and on the Dark side Parsimony, Alacrity, Manifestation, Ebullience and the
  merit ones. The stratagem is used right before the spell, whichever part of Vanguard casts it.
- **Keep for emergencies:** charges only spent on Raise (Celerity) and emergency cures.

## Profiles and thresholds, CurePlease-style (new in 0.14.0 / Vanguard Control 1.3.0)

Everything is chosen in Vanguard Control and kept there; the addon only carries it out.
- **Profiles.** The bar above the tabs: **Save as...** keeps the character's whole setup for its job (role, weapon
  skill, abilities and their thresholds, cure tiers, buffs, songs, Geo, enfeebles, modules, recovery and the other
  settings) as a file in `VanguardControl\profiles`. **Load** puts any profile onto any character (a WHM profile on a
  character that's on another job waits until it's on WHM). **Load by itself on <job>** loads it whenever that
  character logs in or changes to that job.
- **Ability thresholds.** Next to every ability on the Job tab: party HP / my HP / MP / TP limits, how often, and
  when (always, party fighting, I'm fighting, out of combat). Changed values are outlined; the tooltip shows the
  recommended one; clear a box to go back to it.
- **Cure tiers** (Healing & MP tab): how much HP must be missing before each Cure tier is used; 0 = never.
- **Recovery:** rest HP / MP limits, Convert and Sublimation thresholds, for every job with MP.

## The app does the work (new in 0.13.0 / Vanguard Control 1.2.0)

- **Installs Vanguard for you.** Vanguard Control finds the Windower folder (or asks you to pick it), installs the
  addon that's built into the app into `Windower\addons\Vanguard`, and adds `lua load vanguard` to `scripts\init.txt`.
  Settings are never touched.
- **Keeps it up to date.** A newer app carries a newer addon: it installs it and reloads Vanguard on characters still
  running the old one. A yellow bar at the top says if anything needs you (pick a folder, start the game, ...).
- **Team tab.** Everything for the whole party in one place: set up / invite, hold / come / camp / retreat,
  formation, GearSwap defense, fighting rules, bar spells, Corsair rolls, sleeping extra mobs, XP party, team setups,
  and the helpers (alerts, mount, food / Reraise, sneak, rest, overview box, away pause).
- **Job extras** on the Job tab: Scholar skillchains, Corsair roll set / risk / reach, Bard NiTro and Pianissimo
  songs, Geomancer hate list / Entrust / Radial Arcana, Red Mage Saboteur / Stymie, -na for the party.
- **App & updates tab:** versions, Windower folder, check for updates, reinstall, reload everyone.

## Updates and sharing (new in 0.12.0)

Vanguard has its own GitHub page: github.com/Daviant123/Vanguard (the addon is in the **Vanguard** folder, the panel
in **VanguardControl**). Friends who install it from there get told when there's a new version, and
`//vg update install` fetches it (only Vanguard's own files, never settings), then `//lua r vanguard`.
`//vg update` checks now, `//vg update off` stops the check when it loads.
Vanguard Control 1.1.0+ updates itself the same way when it starts (and every 6 hours): it downloads the new panel
and restarts. An empty `noupdate.txt` next to the exe turns that off.

## Commands (same as the panel)

```
//vg on | off | status | save | help
//vg role <role>              e.g. healer, support, nuker, melee, tank, ranged, pet
//vg ws <weapon skill>        empty = off
//vg action <id> on|off|toggle
//vg reset                    recommended setup for this job
//vg autosetup                reload this job's saved setup
//vg leader <name> | none
//vg <module> on|off|toggle
//vg preset melee|healer|curer|bard|geo|nuker|farmer|none
//vg route record | stop | clear | show
//vg set <section.key> <value>
//vg trigger add <rule> | list | clear
//vg all <command>            run on every character
//vg alerts | mountsync | upkeep on|off
//vg party [accept on|off]    //vg formation spread|line|off
//vg hold | come | camp [off]  (on the leader)
//vg hud on|off    //vg stealth on|off    //vg restsync on|off
//vg retreat                  (on the leader)
//vg keys on|off              Ctrl+F1..F6 hotkeys for alt orders
//vg setup save|load|list|delete <name>    //vg exp <mobs> | off
//vg send | sendall <command>  //vg sendto <name> <command>
//vg defense physical|magical|off    //vg gs <GearSwap command>
//vg food <item> | off        //vg reraise auto | <spell or item> | off
//vg to <name> <command>      run on one character
```

## Modules

| Module | What it does | Key settings |
|---|---|---|
| follow | Follows the leader | `follow.distance` |
| assist | Engages what the leader fights, closes to melee range | `assist.approach` (off for casters) |
| actions | Job abilities from the Abilities list | per-job toggles in the panel |
| heal | Cure/Curaga by missing HP; priority members first; wakes sleeping members | `heal.cure_at`, `heal.curaga_at`, `heal.priority`, `heal.wake_sleep` |
| raise | Raises KO'd party members | |
| cleanse | -na spells, Esuna, and Erase for ~30 debuffs | |
| mana | Sublimation upkeep and release, Convert at low MP | `mana.sublimation_mpp`, `mana.convert_mpp` |
| rest | `/heal` when idle and low, stands at full | `rest.hp_low`, `rest.mp_low` |
| buffs | Extra buffs you list | `buffs.list` e.g. `Haste>CharA,Refresh>me` |
| ws | Weapon skill at a TP threshold | `ws.tp` |
| sc | Coordinated skillchains | `sc.steps` e.g. `CharA:Savage Blade,CharC:Chant du Cygne` |
| burst | Magic bursts on detected skillchains | `burst.spells` |
| songs | Keeps songs up (set by BRD role) | `songs.list` |
| geo | Indi, luopan, Entrust, Full Circle (set by GEO role) | `geo.indi`, `geo.geo`, `geo.entrust` |
| debuff | Lands enfeebles once per mob (set by job) | `debuff.list` |
| dispel | Dispels when the battle target buffs itself | best-effort |
| triggers | If-this-then-that rules | see below |
| trusts | Summons trusts until the party is full | `trusts.list` |
| farm | Finds, claims and fights listed mobs; walks a recorded route | `farm.targets`, `farm.claim` |

## Farming (EasyFarm-style)

```
//vg preset farmer
//vg set farm.targets Locus Dire Bat, Locus Wivre
//vg set trusts.list Valaineral,Selh'teus,Koru-Moru,Qultada
//vg route record      (walk your loop)
//vg route stop
//vg on
```

## Triggers

```
//vg trigger add hpp<35 and engaged -> input /ja "Sentinel" <me> | 60
//vg trigger add readies:Hurricane Wing -> input /ma "Stoneskin" <me> | 30
```
Conditions: `hpp`, `mpp`, `tp` (with `< <= > >= ==`), `hpp:Name<50`, `party_hpp<50`, `mob_hpp<25`,
`buff:Name`, `!buff:Name`, `engaged`, `idle`, `resting`, `mob:Name`, `readies:Ability`, `casts:Spell`, `chat:text`.
Join with `and`. Optional `| seconds` cooldown (default 10), or `| once` for once per mob.

## Notes

- The addon runs on a 0.25 s timer and only watches a few packet types, so it is light on FFXI.
- The desktop app talks to the addons over UDP on 127.0.0.1 only. Nothing leaves the PC.
- Test in easy content first.
