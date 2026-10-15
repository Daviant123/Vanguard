--[[
Vanguard job knowledge base.

For every job: the roles it can fill, the abilities/spells worth automating
(with the conditions they should be used under), preferred weapon skills,
and the module configuration each role should start with.

Action fields
  id       unique key (used for on/off toggles)
  label    text shown in the control panel
  group    Buffs | Offense | Defense | Healing | Support | Debuffs | Pet | Recovery
  kind     ja | ma | ra (ranged attack) | roll (COR) | nuke (best available tier) | pet
  name     exact in-game name (for nuke: list of element spell bases)
  target   <me> | <t> | <bt> | {leader} | lowest (lowest-HP party member)
  when     engaged | combat (party fighting) | idle | always
  buff     keep this buff up on the target (spells fall back to their own status)
  buff_any any of these buffs counts as "up" (Utsusemi shadows)
  buff_ids buff ids that count as "up" (when a name is ambiguous, e.g. storm I / II)
  hpp_below / mpp_below / mpp_above / tp_min / tp_max   your own stats
  party_below  lowest party member HP% below this (healing actions)
  once     once per enemy
  cooldown minimum seconds between uses (default 5)
  pet      none (only without a pet) | present (only with a pet)
  no_pld   skip while a Paladin is in the party (Majesty is better than Protect)
  on       roles where this starts enabled (true = all roles)

Only actions the character can actually use right now (job, sub job, level,
spells learned) are shown and executed, so sub-job abilities appear
automatically (e.g. /WAR gives Berserk and Warcry to anyone).
]]

local jobs = {}

local function A(id, label, group, kind, name, opts)
    local a = opts or {}
    a.id, a.label, a.group, a.kind, a.name = id, label, group, kind, name
    a.target = a.target or ((kind == 'ja' or kind == 'roll') and '<me>' or '<me>')
    a.when = a.when or 'engaged'
    return a
end

local COPY = {'Copy Image', 'Copy Image (2)', 'Copy Image (3)', 'Copy Image (4+)'}

------------------------------------------------------------------------
-- Role templates: which modules each role turns on
------------------------------------------------------------------------
jobs.role_modules = {
    tank     = {assist = true, ws = true, actions = true, triggers = true},
    melee    = {follow = true, assist = true, ws = true, actions = true, triggers = true},
    ranged   = {follow = true, assist = true, ws = true, actions = true, triggers = true},
    healer   = {follow = true, heal = true, raise = true, cleanse = true, mana = true, rest = true, actions = true, triggers = true},
    support  = {follow = true, debuff = true, actions = true, rest = true, triggers = true},
    nuker    = {follow = true, burst = true, debuff = true, mana = true, rest = true, actions = true, triggers = true},
    pet      = {follow = true, assist = true, ws = true, actions = true, triggers = true},
}
jobs.role_modules.support_caster = jobs.role_modules.support
-- Roles that should not run into melee range.
jobs.ranged_roles = {ranged = true, healer = true, support = true, nuker = true, support_caster = true}

jobs.role_labels = {
    tank = 'Tank', melee = 'Melee DPS', ranged = 'Ranged DPS', healer = 'Healer',
    support = 'Support (melee party)', support_caster = 'Support (caster party)',
    nuker = 'Nuker', pet = 'Pet DPS',
}

------------------------------------------------------------------------
-- Shared sub-job style blocks (appear for any job that can use them)
------------------------------------------------------------------------
local common = {
    A('berserk', 'Berserk', 'Buffs', 'ja', 'Berserk', {buff = 'Berserk', on = {melee = true, pet = true}}),
    A('warcry', 'Warcry', 'Buffs', 'ja', 'Warcry', {buff = 'Warcry', on = {melee = true, tank = true}}),
    A('aggressor', 'Aggressor', 'Buffs', 'ja', 'Aggressor', {buff = 'Aggressor', on = {melee = true}}),
    A('provoke', 'Provoke (hold hate)', 'Defense', 'ja', 'Provoke', {target = '<t>', cooldown = 30, on = {tank = true}}),
    A('hasso', 'Hasso', 'Buffs', 'ja', 'Hasso', {buff = 'Hasso', on = {melee = true}}),
    A('meditate', 'Meditate (build TP)', 'Offense', 'ja', 'Meditate', {tp_max = 1000, on = {melee = true}}),
    A('third_eye', 'Third Eye', 'Defense', 'ja', 'Third Eye', {buff = 'Third Eye'}),
    A('jump', 'Jump', 'Offense', 'ja', 'Jump', {target = '<t>', tp_max = 1000, on = {melee = true}}),
    A('high_jump', 'High Jump', 'Offense', 'ja', 'High Jump', {target = '<t>', tp_max = 1000, on = {melee = true}}),
    A('utsu_ni', 'Utsusemi: Ni (keep shadows)', 'Defense', 'ma', 'Utsusemi: Ni', {buff_any = COPY, when = 'combat', on = {tank = true}}),
    A('utsu_ichi', 'Utsusemi: Ichi (keep shadows)', 'Defense', 'ma', 'Utsusemi: Ichi', {buff_any = COPY, when = 'combat', on = {tank = true}}),
    A('haste_samba', 'Haste Samba', 'Buffs', 'ja', 'Haste Samba', {buff = 'Haste Samba', on = {melee = true}}),
    A('waltz3', 'Curing Waltz III (party heal)', 'Healing', 'ja', 'Curing Waltz III', {target = 'lowest', party_below = 50, when = 'always', cooldown = 6, on = true}),
    A('waltz2', 'Curing Waltz II (party heal)', 'Healing', 'ja', 'Curing Waltz II', {target = 'lowest', party_below = 45, when = 'always', cooldown = 6}),
    A('box_step', 'Box Step (lower defense)', 'Debuffs', 'ja', 'Box Step', {target = '<t>', cooldown = 30}),
    A('light_arts', 'Light Arts', 'Buffs', 'ja', 'Light Arts', {buff = 'Light Arts', when = 'always', on = {healer = true}}),
    A('dark_arts', 'Dark Arts', 'Buffs', 'ja', 'Dark Arts', {buff = 'Dark Arts', when = 'always', on = {nuker = true}}),
    A('refresh_self', 'Refresh (self)', 'Buffs', 'ma', 'Refresh', {when = 'always', on = {healer = true, nuker = true, support = true, tank = true}}),
    A('phalanx_self', 'Phalanx (self)', 'Defense', 'ma', 'Phalanx', {when = 'combat', on = {tank = true}}),
    A('stoneskin', 'Stoneskin', 'Defense', 'ma', 'Stoneskin', {when = 'combat'}),
    A('blink', 'Blink', 'Defense', 'ma', 'Blink', {when = 'combat'}),
    A('aquaveil', 'Aquaveil', 'Defense', 'ma', 'Aquaveil', {when = 'always'}),
    A('haste_leader', 'Haste on leader', 'Support', 'ma', 'Haste', {target = '{leader}', when = 'always', on = {healer = true, support = true}}),
    A('cure_self', 'Cure IV on self when low', 'Healing', 'ma', 'Cure IV', {hpp_below = 50, when = 'always', on = {tank = true}}),
    A('flash', 'Flash (enmity)', 'Defense', 'ma', 'Flash', {target = '<t>', cooldown = 20, on = {tank = true}}),
    A('reraise', 'Reraise (self)', 'Recovery', 'ma', 'Reraise', {buff = 'Reraise', when = 'idle'}),
}

------------------------------------------------------------------------
-- Jobs
------------------------------------------------------------------------
jobs.WAR = {
    roles = {'melee', 'tank'},
    ws = {"Ukko's Fury", 'Upheaval', "King's Justice", 'Savage Blade', 'Resolution', 'Steel Cyclone', 'Raging Rush', 'Fell Cleave'},
    actions = {
        A('restraint', 'Restraint', 'Buffs', 'ja', 'Restraint', {buff = 'Restraint', on = {melee = true}}),
        A('blood_rage', 'Blood Rage', 'Buffs', 'ja', 'Blood Rage', {buff = 'Blood Rage', on = {melee = true}}),
        A('retaliation', 'Retaliation', 'Defense', 'ja', 'Retaliation', {buff = 'Retaliation', on = {tank = true}}),
        A('defender', 'Defender', 'Defense', 'ja', 'Defender', {buff = 'Defender', on = {tank = true}}),
        A('warriors_charge', "Warrior's Charge (before WS)", 'Offense', 'ja', "Warrior's Charge", {tp_min = 1000, on = {melee = true}}),
        A('tomahawk', 'Tomahawk (new mob)', 'Debuffs', 'ja', 'Tomahawk', {target = '<t>', once = true}),
        A('mighty_strikes', 'Mighty Strikes (2-hour)', 'Offense', 'ja', 'Mighty Strikes', {}),
    },
}

jobs.MNK = {
    roles = {'melee', 'tank'},
    ws = {'Victory Smite', 'Shijin Spiral', 'Raging Fists', 'Howling Fist', 'Asuran Fists', 'Combo'},
    actions = {
        A('impetus', 'Impetus', 'Buffs', 'ja', 'Impetus', {buff = 'Impetus', on = {melee = true}}),
        A('focus', 'Focus', 'Buffs', 'ja', 'Focus', {buff = 'Focus', on = {melee = true}}),
        A('dodge', 'Dodge', 'Defense', 'ja', 'Dodge', {buff = 'Dodge', on = {tank = true}}),
        A('footwork', 'Footwork', 'Offense', 'ja', 'Footwork', {buff = 'Footwork'}),
        A('counterstance', 'Counterstance', 'Defense', 'ja', 'Counterstance', {buff = 'Counterstance', on = {tank = true}}),
        A('chakra', 'Chakra when HP < 50%', 'Recovery', 'ja', 'Chakra', {hpp_below = 50, when = 'always', on = true}),
        A('mantra', 'Mantra', 'Defense', 'ja', 'Mantra', {}),
        A('hundred_fists', 'Hundred Fists (2-hour)', 'Offense', 'ja', 'Hundred Fists', {}),
    },
}

jobs.WHM = {
    roles = {'healer'},
    ws = {'Black Halo', 'Hexa Strike', 'Realmrazer', 'Judgment'},
    actions = {
        A('afflatus_solace', 'Afflatus Solace', 'Buffs', 'ja', 'Afflatus Solace', {buff = 'Afflatus Solace', when = 'always', on = {healer = true}}),
        A('divine_seal', 'Divine Seal when party is low', 'Healing', 'ja', 'Divine Seal', {party_below = 40, when = 'always', on = {healer = true}}),
        A('benediction', 'Benediction when party is critical (2-hour)', 'Healing', 'ja', 'Benediction', {party_below = 20, when = 'always'}),
        A('regen_leader', 'Regen IV on leader', 'Support', 'ma', 'Regen IV', {target = '{leader}', when = 'combat', on = {healer = true}}),
        A('protectra', 'Protectra V', 'Buffs', 'ma', 'Protectra V', {buff = 'Protect', when = 'always', no_pld = true, on = {healer = true}}),
        A('shellra', 'Shellra V', 'Buffs', 'ma', 'Shellra V', {buff = 'Shell', when = 'always', on = {healer = true}}),
        A('auspice', 'Auspice', 'Buffs', 'ma', 'Auspice', {when = 'combat', on = {healer = true}}),
        A('reraise4', 'Reraise IV (self)', 'Recovery', 'ma', 'Reraise IV', {buff = 'Reraise', when = 'idle', on = {healer = true}}),
        A('boost_str', 'Boost-STR', 'Buffs', 'ma', 'Boost-STR', {when = 'combat'}),
    },
}

jobs.BLM = {
    roles = {'nuker'},
    ws = {'Myrkr', 'Vidohunir', 'Shattersoul'},
    actions = {
        A('free_nuke', 'Free nuke (best tier) between bursts', 'Offense', 'nuke', {'Thunder', 'Blizzard', 'Fire', 'Aero', 'Water', 'Stone'},
          {target = '<bt>', when = 'combat', mpp_above = 30, cooldown = 3, on = {nuker = true}}),
        A('aspir', 'Aspir III when MP < 50%', 'Recovery', 'ma', 'Aspir III', {target = '<bt>', when = 'combat', mpp_below = 50, on = {nuker = true}}),
        A('aspir2', 'Aspir II when MP < 50%', 'Recovery', 'ma', 'Aspir II', {target = '<bt>', when = 'combat', mpp_below = 50, on = {nuker = true}}),
        A('elemental_seal', 'Elemental Seal', 'Offense', 'ja', 'Elemental Seal', {when = 'combat'}),
        A('manawall', 'Mana Wall', 'Defense', 'ja', 'Mana Wall', {buff = 'Mana Wall', when = 'combat'}),
        A('manafont', 'Manafont (2-hour)', 'Offense', 'ja', 'Manafont', {when = 'combat'}),
    },
}

jobs.RDM = {
    roles = {'support', 'nuker', 'melee'},
    ws = {'Savage Blade', 'Chant du Cygne', 'Requiescat', 'Sanguine Blade', 'Seraph Blade', 'Death Blossom', 'Black Halo'},
    actions = {
        A('composure', 'Composure', 'Buffs', 'ja', 'Composure', {buff = 'Composure', when = 'always', on = true}),
        A('refresh3_leader', 'Refresh III on leader', 'Support', 'ma', 'Refresh III', {target = '{leader}', when = 'always', on = {support = true}}),
        A('refresh3_self', 'Refresh III (self)', 'Buffs', 'ma', 'Refresh III', {when = 'always', on = true}),
        A('haste2_leader', 'Haste II on leader', 'Support', 'ma', 'Haste II', {target = '{leader}', when = 'always', on = {support = true}}),
        A('haste2_self', 'Haste II (self)', 'Buffs', 'ma', 'Haste II', {when = 'always', on = {melee = true}}),
        A('phalanx2_leader', 'Phalanx II on leader', 'Support', 'ma', 'Phalanx II', {target = '{leader}', when = 'combat', on = {support = true}}),
        A('temper2', 'Temper II', 'Buffs', 'ma', 'Temper II', {when = 'combat', on = {melee = true}}),
        A('gain_str', 'Gain-STR', 'Buffs', 'ma', 'Gain-STR', {when = 'combat', on = {melee = true}}),
        A('enfire2', 'Enfire II', 'Offense', 'ma', 'Enfire II', {when = 'combat', on = {melee = true}}),
        A('free_nuke', 'Free nuke (best tier)', 'Offense', 'nuke', {'Thunder', 'Blizzard', 'Fire', 'Aero', 'Water', 'Stone'},
          {target = '<bt>', when = 'combat', mpp_above = 40, cooldown = 4, on = {nuker = true}}),
        A('saboteur', 'Saboteur', 'Debuffs', 'ja', 'Saboteur', {when = 'combat'}),
        A('convert', 'Convert at low MP', 'Recovery', 'ja', 'Convert', {mpp_below = 15, hpp_below = 101, when = 'always', on = true}),
    },
    debuffs = {support = 'Dia III,Distract III,Frazzle III,Slow II,Paralyze II', nuker = 'Dia III,Frazzle III'},
}

jobs.THF = {
    roles = {'melee', 'tank'},
    ws = {"Rudra's Storm", 'Evisceration', 'Exenterator', 'Savage Blade', 'Aeolian Edge'},
    actions = {
        A('sneak_attack', 'Sneak Attack (before WS)', 'Offense', 'ja', 'Sneak Attack', {tp_min = 1000, on = {melee = true}}),
        A('trick_attack', 'Trick Attack (before WS)', 'Offense', 'ja', 'Trick Attack', {tp_min = 1000}),
        A('feint', 'Feint', 'Debuffs', 'ja', 'Feint', {cooldown = 60, on = {melee = true}}),
        A('conspirator', 'Conspirator', 'Buffs', 'ja', 'Conspirator', {buff = 'Conspirator', on = {melee = true}}),
        A('bully', 'Bully', 'Offense', 'ja', 'Bully', {target = '<t>', once = true}),
        A('despoil', 'Despoil', 'Offense', 'ja', 'Despoil', {target = '<t>', cooldown = 60}),
    },
}

jobs.PLD = {
    roles = {'tank'},
    ws = {'Savage Blade', 'Chant du Cygne', 'Requiescat', 'Atonement', 'Sanguine Blade'},
    actions = {
        A('majesty', 'Majesty', 'Buffs', 'ja', 'Majesty', {buff = 'Majesty', when = 'combat', on = {tank = true}}),
        A('crusade', 'Crusade', 'Buffs', 'ma', 'Crusade', {when = 'always', on = {tank = true}}),
        A('phalanx', 'Phalanx', 'Defense', 'ma', 'Phalanx', {when = 'always', on = {tank = true}}),
        A('reprisal', 'Reprisal', 'Defense', 'ma', 'Reprisal', {when = 'combat', on = {tank = true}}),
        A('enlight2', 'Enlight II', 'Offense', 'ma', 'Enlight II', {when = 'combat', on = {tank = true}}),
        A('protect5', 'Protect V', 'Defense', 'ma', 'Protect V', {buff = 'Protect', when = 'always', on = {tank = true}}),
        A('shell4', 'Shell IV', 'Defense', 'ma', 'Shell IV', {buff = 'Shell', when = 'always', on = {tank = true}}),
        A('flash_pld', 'Flash (enmity)', 'Defense', 'ma', 'Flash', {target = '<t>', cooldown = 20, on = {tank = true}}),
        A('shield_bash', 'Shield Bash', 'Defense', 'ja', 'Shield Bash', {target = '<t>', cooldown = 15, on = {tank = true}}),
        A('palisade', 'Palisade', 'Defense', 'ja', 'Palisade', {buff = 'Palisade', on = {tank = true}}),
        A('sentinel', 'Sentinel when HP < 40%', 'Defense', 'ja', 'Sentinel', {hpp_below = 40, on = {tank = true}}),
        A('rampart', 'Rampart when party is low', 'Defense', 'ja', 'Rampart', {party_below = 50, when = 'combat', on = {tank = true}}),
        A('chivalry', 'Chivalry at low MP', 'Recovery', 'ja', 'Chivalry', {mpp_below = 20, tp_min = 1000, on = {tank = true}}),
        A('cure4_self', 'Cure IV on self when low', 'Healing', 'ma', 'Cure IV', {hpp_below = 55, when = 'always', on = {tank = true}}),
        A('invincible', 'Invincible (2-hour)', 'Defense', 'ja', 'Invincible', {hpp_below = 25}),
    },
}

jobs.DRK = {
    roles = {'melee', 'tank'},
    ws = {'Torcleaver', 'Resolution', 'Insurgency', 'Cross Reaper', 'Catastrophe', 'Entropy', 'Savage Blade'},
    actions = {
        A('last_resort', 'Last Resort', 'Buffs', 'ja', 'Last Resort', {buff = 'Last Resort', on = {melee = true}}),
        A('arcane_circle', 'Arcane Circle', 'Buffs', 'ja', 'Arcane Circle', {buff = 'Arcane Circle', on = {melee = true}}),
        A('scarlet_delirium', 'Scarlet Delirium', 'Buffs', 'ja', 'Scarlet Delirium', {buff = 'Scarlet Delirium', on = {melee = true}}),
        A('endark2', 'Endark II', 'Buffs', 'ma', 'Endark II', {buff = 'Endark', when = 'combat', on = {melee = true}}),
        A('dread_spikes', 'Dread Spikes', 'Defense', 'ma', 'Dread Spikes', {when = 'combat', on = {tank = true}}),
        A('absorb_tp', 'Absorb-TP', 'Debuffs', 'ma', 'Absorb-TP', {target = '<t>', cooldown = 60}),
        A('drain3', 'Drain III when HP < 50%', 'Recovery', 'ma', 'Drain III', {target = '<t>', hpp_below = 50, on = true}),
        A('stun', 'Stun', 'Debuffs', 'ma', 'Stun', {target = '<t>', cooldown = 45}),
        A('souleater', 'Souleater', 'Offense', 'ja', 'Souleater', {}),
    },
}

jobs.BST = {
    roles = {'pet', 'melee'},
    ws = {'Decimation', 'Ruinator', 'Cloudsplitter', 'Mistral Axe', 'Primal Rend', 'Rampage'},
    actions = {
        A('call_beast', 'Call Beast (needs a jug equipped)', 'Pet', 'ja', 'Call Beast', {pet = 'none', when = 'idle', on = {pet = true}}),
        A('bestial_loyalty', 'Bestial Loyalty (needs a jug equipped)', 'Pet', 'ja', 'Bestial Loyalty', {pet = 'none', when = 'idle', on = {pet = true}}),
        A('fight', 'Fight (send pet in)', 'Pet', 'ja', 'Fight', {target = '<t>', pet = 'present', once = true, on = {pet = true}}),
        A('killer_instinct', 'Killer Instinct', 'Buffs', 'ja', 'Killer Instinct', {pet = 'present'}),
        A('spur', 'Spur', 'Pet', 'ja', 'Spur', {pet = 'present', cooldown = 180}),
    },
}

jobs.BRD = {
    roles = {'support', 'support_caster'},
    ws = {"Rudra's Storm", 'Savage Blade', 'Evisceration', 'Mordant Rime'},
    songs = {
        support = 'Honor March,Valor Minuet V,Valor Minuet IV,Blade Madrigal',
        support_caster = "Mage's Ballad III,Mage's Ballad II,Sage Etude,Arcane Etude",
    },
    debuffs = {support = 'Carnage Elegy', support_caster = 'Carnage Elegy'},
    actions = {
        A('nightingale', 'Nightingale', 'Support', 'ja', 'Nightingale', {when = 'combat'}),
        A('troubadour', 'Troubadour', 'Support', 'ja', 'Troubadour', {when = 'combat'}),
        A('marcato', 'Marcato', 'Support', 'ja', 'Marcato', {when = 'combat'}),
        A('soul_voice', 'Soul Voice (2-hour)', 'Support', 'ja', 'Soul Voice', {}),
    },
}

jobs.RNG = {
    roles = {'ranged'},
    ws = {'Last Stand', 'Trueflight', "Jishnu's Radiance", 'Coronach', 'Empyreal Arrow', 'Hot Shot', 'Wildfire'},
    actions = {
        A('auto_ra', 'Ranged attack loop', 'Offense', 'ra', 'Ranged', {target = '<t>', cooldown = 0, on = {ranged = true}}),
        A('velocity_shot', 'Velocity Shot', 'Buffs', 'ja', 'Velocity Shot', {buff = 'Velocity Shot', on = {ranged = true}}),
        A('double_shot', 'Double Shot', 'Buffs', 'ja', 'Double Shot', {buff = 'Double Shot', on = {ranged = true}}),
        A('sharpshot', 'Sharpshot', 'Buffs', 'ja', 'Sharpshot', {buff = 'Sharpshot', on = {ranged = true}}),
        A('barrage', 'Barrage', 'Offense', 'ja', 'Barrage', {buff = 'Barrage'}),
        A('hover_shot', 'Hover Shot', 'Buffs', 'ja', 'Hover Shot', {buff = 'Hover Shot', on = {ranged = true}}),
        A('decoy_shot', 'Decoy Shot', 'Defense', 'ja', 'Decoy Shot', {buff = 'Decoy Shot'}),
        A('bounty_shot', 'Bounty Shot (new mob)', 'Offense', 'ja', 'Bounty Shot', {target = '<t>', once = true}),
    },
}

jobs.SAM = {
    roles = {'melee', 'tank'},
    ws = {'Tachi: Fudo', 'Tachi: Shoha', 'Tachi: Kasha', 'Tachi: Rana', 'Tachi: Jinpu', 'Tachi: Gekko'},
    actions = {
        A('sekkanoki', 'Sekkanoki (before WS)', 'Offense', 'ja', 'Sekkanoki', {tp_min = 1000, on = {melee = true}}),
        A('seigan', 'Seigan', 'Defense', 'ja', 'Seigan', {buff = 'Seigan', on = {tank = true}}),
        A('konzen', 'Konzen-ittai', 'Offense', 'ja', 'Konzen-ittai', {tp_min = 1000}),
        A('sengikori', 'Sengikori', 'Offense', 'ja', 'Sengikori', {tp_min = 1000}),
        A('hagakure', 'Hagakure', 'Offense', 'ja', 'Hagakure', {tp_min = 1000}),
        A('meikyo', 'Meikyo Shisui (2-hour)', 'Offense', 'ja', 'Meikyo Shisui', {}),
    },
}

jobs.NIN = {
    roles = {'tank', 'melee'},
    ws = {'Blade: Hi', 'Blade: Shun', 'Blade: Metsu', 'Blade: Ten', 'Blade: Ku', 'Evisceration'},
    actions = {
        A('utsu_san', 'Utsusemi: San (keep shadows)', 'Defense', 'ma', 'Utsusemi: San', {buff_any = COPY, when = 'combat', on = true}),
        A('yonin', 'Yonin', 'Defense', 'ja', 'Yonin', {buff = 'Yonin', on = {tank = true}}),
        A('innin', 'Innin', 'Buffs', 'ja', 'Innin', {buff = 'Innin', on = {melee = true}}),
        A('issekigan', 'Issekigan', 'Defense', 'ja', 'Issekigan', {buff = 'Issekigan', on = {tank = true}}),
        A('migawari', 'Migawari: Ichi', 'Defense', 'ma', 'Migawari: Ichi', {when = 'combat', on = {tank = true}}),
        A('kakka', 'Kakka: Ichi', 'Buffs', 'ma', 'Kakka: Ichi', {when = 'combat', on = true}),
        A('myoshu', 'Myoshu: Ichi', 'Buffs', 'ma', 'Myoshu: Ichi', {when = 'combat', on = {melee = true}}),
        A('kurayami', 'Kurayami: Ni', 'Debuffs', 'ma', 'Kurayami: Ni', {target = '<t>', once = true, on = {tank = true}}),
        A('hojo', 'Hojo: Ni', 'Debuffs', 'ma', 'Hojo: Ni', {target = '<t>', once = true, on = {tank = true}}),
        A('jubaku', 'Jubaku: Ichi', 'Debuffs', 'ma', 'Jubaku: Ichi', {target = '<t>', once = true}),
    },
}

jobs.DRG = {
    roles = {'melee'},
    ws = {'Stardiver', "Camlann's Torment", 'Drakesbane', 'Geirskogul', 'Impulse Drive', 'Sonic Thrust'},
    actions = {
        A('call_wyvern', 'Call Wyvern', 'Pet', 'ja', 'Call Wyvern', {pet = 'none', when = 'always', on = true}),
        A('spirit_jump', 'Spirit Jump', 'Offense', 'ja', 'Spirit Jump', {target = '<t>', tp_max = 1000, on = {melee = true}}),
        A('soul_jump', 'Soul Jump', 'Offense', 'ja', 'Soul Jump', {target = '<t>', tp_max = 1000, on = {melee = true}}),
        A('angon', 'Angon (new mob)', 'Debuffs', 'ja', 'Angon', {target = '<t>', once = true}),
        A('spirit_link', 'Spirit Link when HP is low', 'Recovery', 'ja', 'Spirit Link', {hpp_below = 40, pet = 'present'}),
    },
}

jobs.SMN = {
    roles = {'support', 'pet'},
    ws = {'Garland of Bliss', 'Shattersoul', 'Retribution'},
    actions = {
        A('summon_garuda', 'Keep Garuda out', 'Pet', 'ma', 'Garuda', {pet = 'none', when = 'always', on = {support = true}}),
        A('summon_ifrit', 'Keep Ifrit out', 'Pet', 'ma', 'Ifrit', {pet = 'none', when = 'always', on = {pet = true}}),
        A('avatars_favor', "Avatar's Favor", 'Support', 'ja', "Avatar's Favor", {buff = "Avatar's Favor", pet = 'present', when = 'always', on = true}),
        A('hastega2', 'Hastega II (Garuda)', 'Support', 'ja', 'Hastega II', {buff = 'Haste', pet = 'present', when = 'combat', on = {support = true}}),
        A('crystal_blessing', 'Crystal Blessing (Shiva)', 'Support', 'ja', 'Crystal Blessing', {pet = 'present', when = 'combat', cooldown = 180}),
        A('assault', 'Assault (send avatar in)', 'Pet', 'ja', 'Assault', {target = '<bt>', pet = 'present', when = 'combat', once = true, on = {pet = true}}),
        A('apogee', 'Apogee', 'Pet', 'ja', 'Apogee', {pet = 'present', when = 'combat'}),
    },
}

jobs.BLU = {
    roles = {'melee', 'tank', 'nuker'},
    ws = {'Expiacion', 'Chant du Cygne', 'Savage Blade', 'Requiescat', 'Sanguine Blade'},
    actions = {
        A('erratic_flutter', 'Erratic Flutter (Haste)', 'Buffs', 'ma', 'Erratic Flutter', {when = 'combat', on = true}),
        A('cocoon', 'Cocoon', 'Defense', 'ma', 'Cocoon', {when = 'combat', on = {tank = true}}),
        A('nat_meditation', 'Nat. Meditation', 'Buffs', 'ma', 'Nat. Meditation', {when = 'combat', on = {melee = true}}),
        A('barrier_tusk', 'Barrier Tusk', 'Defense', 'ma', 'Barrier Tusk', {when = 'combat', on = {tank = true}}),
        A('occultation', 'Occultation (blink)', 'Defense', 'ma', 'Occultation', {buff = 'Blink', when = 'combat', on = {tank = true}}),
        A('battery_charge', 'Battery Charge (refresh)', 'Buffs', 'ma', 'Battery Charge', {when = 'always', on = true}),
        A('mighty_guard', 'Mighty Guard', 'Defense', 'ma', 'Mighty Guard', {when = 'combat'}),
        A('magic_fruit', 'Magic Fruit when HP < 50%', 'Healing', 'ma', 'Magic Fruit', {hpp_below = 50, when = 'always', on = true}),
        A('free_nuke_blu', 'Free nuke (Spectral Floe)', 'Offense', 'ma', 'Spectral Floe', {target = '<bt>', when = 'combat', cooldown = 10, on = {nuker = true}}),
    },
}

-- Phantom Roll {lucky, unlucky} numbers (used for automatic Double-Up / Snake Eye).
jobs.lucky = {
    ["Chaos Roll"] = {4, 8}, ["Samurai Roll"] = {2, 6}, ["Fighter's Roll"] = {5, 9}, ["Hunter's Roll"] = {4, 8},
    ["Wizard's Roll"] = {5, 9}, ["Warlock's Roll"] = {4, 8}, ["Evoker's Roll"] = {5, 9}, ["Corsair's Roll"] = {5, 9},
    ["Allies' Roll"] = {3, 10}, ["Rogue's Roll"] = {5, 9}, ["Magus's Roll"] = {2, 6}, ["Gallant's Roll"] = {3, 7},
    ["Monk's Roll"] = {3, 7}, ["Healer's Roll"] = {3, 7}, ["Drachen Roll"] = {4, 8}, ["Choral Roll"] = {2, 6},
    ["Beast Roll"] = {4, 8}, ["Ninja Roll"] = {4, 8}, ["Tactician's Roll"] = {5, 8}, ["Miser's Roll"] = {5, 7},
    ["Companion's Roll"] = {2, 10}, ["Avenger's Roll"] = {4, 8}, ["Naturalist's Roll"] = {3, 7},
    ["Runeist's Roll"] = {4, 8}, ["Bolter's Roll"] = {3, 9}, ["Caster's Roll"] = {2, 7}, ["Courser's Roll"] = {3, 9},
    ["Blitzer's Roll"] = {4, 9}, ["Scholar's Roll"] = {2, 6}, ["Dancer's Roll"] = {3, 7}, ["Puppet Roll"] = {3, 7},
}

jobs.COR = {
    roles = {'support', 'support_caster', 'ranged'},
    ws = {'Leaden Salute', 'Savage Blade', 'Last Stand', 'Wildfire', 'Evisceration'},
    actions = {
        A('roll_samurai', 'Samurai Roll (Store TP)', 'Support', 'roll', 'Samurai Roll', {when = 'combat', on = {support = true, ranged = true}}),
        A('roll_chaos', 'Chaos Roll (Attack)', 'Support', 'roll', 'Chaos Roll', {when = 'combat', on = {support = true, ranged = true}}),
        A('roll_fighters', "Fighter's Roll (Double Attack)", 'Support', 'roll', "Fighter's Roll", {when = 'combat'}),
        A('roll_hunters', "Hunter's Roll (Accuracy)", 'Support', 'roll', "Hunter's Roll", {when = 'combat'}),
        A('roll_wizards', "Wizard's Roll (Magic Attack)", 'Support', 'roll', "Wizard's Roll", {when = 'combat', on = {support_caster = true}}),
        A('roll_warlocks', "Warlock's Roll (Magic Accuracy)", 'Support', 'roll', "Warlock's Roll", {when = 'combat', on = {support_caster = true}}),
        A('roll_rogues', "Rogue's Roll (Critical hit rate)", 'Support', 'roll', "Rogue's Roll", {when = 'combat'}),
        A('roll_casters', "Caster's Roll (Fast Cast)", 'Support', 'roll', "Caster's Roll", {when = 'combat'}),
        A('roll_evokers', "Evoker's Roll (Refresh)", 'Support', 'roll', "Evoker's Roll", {when = 'always'}),
        A('roll_corsairs', "Corsair's Roll (EXP)", 'Support', 'roll', "Corsair's Roll", {when = 'always'}),
        A('auto_ra_cor', 'Ranged attack loop', 'Offense', 'ra', 'Ranged', {target = '<t>', cooldown = 0, on = {ranged = true}}),
        A('triple_shot', 'Triple Shot', 'Buffs', 'ja', 'Triple Shot', {buff = 'Triple Shot', on = {ranged = true}}),
        A('crooked_cards', 'Crooked Cards (before first roll)', 'Support', 'ja', 'Crooked Cards', {when = 'combat'}),
    },
}

jobs.PUP = {
    roles = {'pet', 'melee'},
    ws = {'Victory Smite', 'Shijin Spiral', 'Stringing Pummel', 'Howling Fist', 'Asuran Fists'},
    actions = {
        A('activate', 'Activate automaton', 'Pet', 'ja', 'Activate', {pet = 'none', when = 'idle', on = true}),
        A('deus_ex', 'Deus Ex Automata (if Activate is down)', 'Pet', 'ja', 'Deus Ex Automata', {pet = 'none', when = 'idle', on = true}),
        A('deploy', 'Deploy (send automaton in)', 'Pet', 'ja', 'Deploy', {target = '<t>', pet = 'present', once = true, on = true}),
        A('fire_maneuver', 'Fire Maneuver', 'Pet', 'ja', 'Fire Maneuver', {buff = 'Fire Maneuver', pet = 'present', when = 'combat', on = {pet = true}}),
        A('wind_maneuver', 'Wind Maneuver', 'Pet', 'ja', 'Wind Maneuver', {buff = 'Wind Maneuver', pet = 'present', when = 'combat', on = {pet = true}}),
        A('light_maneuver', 'Light Maneuver', 'Pet', 'ja', 'Light Maneuver', {buff = 'Light Maneuver', pet = 'present', when = 'combat', on = {pet = true}}),
        A('repair', 'Repair when automaton is low (needs oil)', 'Pet', 'ja', 'Repair', {pet = 'present', cooldown = 90}),
        A('cooldown', 'Cooldown (overload relief)', 'Pet', 'ja', 'Cooldown', {pet = 'present', cooldown = 300}),
    },
}

jobs.DNC = {
    roles = {'melee', 'tank'},
    ws = {"Rudra's Storm", 'Pyrrhic Kleos', 'Evisceration', 'Exenterator', 'Aeolian Edge'},
    actions = {
        A('saber_dance', 'Saber Dance', 'Buffs', 'ja', 'Saber Dance', {buff = 'Saber Dance', on = {melee = true}}),
        A('fan_dance', 'Fan Dance', 'Defense', 'ja', 'Fan Dance', {buff = 'Fan Dance', on = {tank = true}}),
        A('waltz4', 'Curing Waltz IV (party heal)', 'Healing', 'ja', 'Curing Waltz IV', {target = 'lowest', party_below = 50, when = 'always', cooldown = 6, on = true}),
        A('divine_waltz2', 'Divine Waltz II (AoE heal)', 'Healing', 'ja', 'Divine Waltz II', {party_below = 40, when = 'always', cooldown = 10}),
        A('healing_waltz', 'Healing Waltz (remove debuff)', 'Healing', 'ja', 'Healing Waltz', {cooldown = 20}),
        A('quickstep', 'Quickstep (lower evasion)', 'Debuffs', 'ja', 'Quickstep', {target = '<t>', cooldown = 25, on = {melee = true}}),
        A('presto', 'Presto (before steps)', 'Offense', 'ja', 'Presto', {cooldown = 30}),
        A('climactic', 'Climactic Flourish (before WS)', 'Offense', 'ja', 'Climactic Flourish', {tp_min = 1000, target = '<t>', on = {melee = true}}),
        A('reverse_flourish', 'Reverse Flourish', 'Offense', 'ja', 'Reverse Flourish', {tp_max = 1000, cooldown = 30}),
        A('animated_flourish', 'Animated Flourish (pull hate)', 'Defense', 'ja', 'Animated Flourish', {target = '<t>', cooldown = 30, on = {tank = true}}),
    },
}

jobs.SCH = {
    roles = {'healer', 'nuker'},
    ws = {'Omniscience', 'Myrkr', 'Black Halo', 'Shattersoul'},
    actions = {
        A('addendum_white', 'Addendum: White', 'Buffs', 'ja', 'Addendum: White', {buff = 'Addendum: White', when = 'always', on = {healer = true}}),
        A('addendum_black', 'Addendum: Black', 'Buffs', 'ja', 'Addendum: Black', {buff = 'Addendum: Black', when = 'always', on = {nuker = true}}),
        A('regen5_leader', 'Regen V on leader', 'Support', 'ma', 'Regen V', {target = '{leader}', when = 'combat', on = {healer = true}}),
        A('protect5_sch', 'Protect V (self)', 'Buffs', 'ma', 'Protect V', {buff = 'Protect', when = 'always', on = {healer = true}}),
        A('shell5_sch', 'Shell V (self)', 'Buffs', 'ma', 'Shell V', {buff = 'Shell', when = 'always', on = {healer = true}}),
        A('reraise3', 'Reraise III (self)', 'Recovery', 'ma', 'Reraise III', {buff = 'Reraise', when = 'idle', on = true}),
        A('aurorastorm', 'Aurorastorm II (self: cures stay strong)', 'Buffs', 'ma', 'Aurorastorm II', {buff_ids = {184, 595}, when = 'always', on = {healer = true}}),
        A('klimaform', 'Klimaform', 'Buffs', 'ma', 'Klimaform', {when = 'combat', on = {nuker = true}}),
        A('storm_fire', 'Firestorm II', 'Buffs', 'ma', 'Firestorm II', {when = 'combat'}),
        A('storm_thunder', 'Thunderstorm II', 'Buffs', 'ma', 'Thunderstorm II', {when = 'combat', on = {nuker = true}}),
        A('free_nuke', 'Free nuke (best tier)', 'Offense', 'nuke', {'Thunder', 'Blizzard', 'Fire', 'Aero', 'Water', 'Stone'},
          {target = '<bt>', when = 'combat', mpp_above = 30, cooldown = 3, on = {nuker = true}}),
        A('helix', 'Ionohelix II (DoT, new mob)', 'Debuffs', 'ma', 'Ionohelix II', {target = '<bt>', when = 'combat', once = true, on = {nuker = true}}),
    },
}

jobs.GEO = {
    roles = {'support', 'support_caster'},
    ws = {'Black Halo', 'Exudation', 'Realmrazer', 'Hexa Strike'},
    geo = {
        support = {indi = 'Indi-Fury', geo = 'Geo-Frailty', geo_target = 'bt'},
        support_caster = {indi = 'Indi-Acumen', geo = 'Geo-Malaise', geo_target = 'bt'},
    },
    debuffs = {support = 'Dia II', support_caster = 'Dia II'},
    actions = {
        A('blaze', 'Blaze of Glory (before Geo)', 'Support', 'ja', 'Blaze of Glory', {pet = 'none', when = 'combat'}),
        A('ecliptic', 'Ecliptic Attrition', 'Support', 'ja', 'Ecliptic Attrition', {pet = 'present', when = 'combat'}),
        A('dematerialize', 'Dematerialize (protect luopan)', 'Support', 'ja', 'Dematerialize', {pet = 'present', when = 'combat'}),
        A('life_cycle', 'Life Cycle', 'Support', 'ja', 'Life Cycle', {pet = 'present', when = 'combat', cooldown = 600}),
        A('radial_arcana', 'Radial Arcana at low MP', 'Recovery', 'ja', 'Radial Arcana', {pet = 'present', mpp_below = 25, when = 'always'}),
    },
}

jobs.RUN = {
    roles = {'tank'},
    ws = {'Dimidiation', 'Resolution', 'Steel Cyclone', 'Shockwave'},
    actions = {
        A('rune', 'Keep a rune up (Tellus)', 'Defense', 'ja', 'Tellus', {buff = 'Tellus', on = {tank = true}}),
        A('vallation', 'Vallation', 'Defense', 'ja', 'Vallation', {buff = 'Vallation', on = {tank = true}}),
        A('valiance', 'Valiance (party)', 'Defense', 'ja', 'Valiance', {buff = 'Valiance'}),
        A('pflug', 'Pflug', 'Defense', 'ja', 'Pflug', {buff = 'Pflug', on = {tank = true}}),
        A('swordplay', 'Swordplay', 'Buffs', 'ja', 'Swordplay', {buff = 'Swordplay', on = {tank = true}}),
        A('battuta', 'Battuta', 'Defense', 'ja', 'Battuta', {buff = 'Battuta', on = {tank = true}}),
        A('foil', 'Foil', 'Defense', 'ma', 'Foil', {when = 'combat', on = {tank = true}}),
        A('crusade_run', 'Crusade', 'Buffs', 'ma', 'Crusade', {when = 'always', on = {tank = true}}),
        A('phalanx_run', 'Phalanx', 'Defense', 'ma', 'Phalanx', {when = 'always', on = {tank = true}}),
        A('temper', 'Temper', 'Buffs', 'ma', 'Temper', {when = 'combat', on = {tank = true}}),
        A('regen4_run', 'Regen IV (self)', 'Recovery', 'ma', 'Regen IV', {when = 'combat', on = {tank = true}}),
        A('flash_run', 'Flash (enmity)', 'Defense', 'ma', 'Flash', {target = '<t>', cooldown = 20, on = {tank = true}}),
        A('vivacious_pulse', 'Vivacious Pulse when HP < 50%', 'Recovery', 'ja', 'Vivacious Pulse', {hpp_below = 50, on = {tank = true}}),
        A('one_for_all', 'One for All', 'Defense', 'ja', 'One for All', {party_below = 40}),
    },
}

------------------------------------------------------------------------
-- Build the full action list for a job (job actions + shared actions).
------------------------------------------------------------------------
function jobs.actions_for(job)
    local def = jobs[job]
    local out, seen = {}, {}
    if def then
        for _, a in ipairs(def.actions) do out[#out + 1] = a; seen[a.id] = true end
    end
    for _, a in ipairs(common) do
        if not seen[a.id] then out[#out + 1] = a; seen[a.id] = true end
    end
    return out
end

function jobs.roles_for(job)
    local def = jobs[job]
    return def and def.roles or {'melee'}
end

function jobs.default_on(action, role)
    if action.on == true then return true end
    return type(action.on) == 'table' and action.on[role] == true
end

return jobs
