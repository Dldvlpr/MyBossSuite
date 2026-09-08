-- tests/fixtures/BossData.lua
-- Rencontres synthetiques pour la suite headless : un world boss a deux npcIds
-- (conseil), un boss de donjon avec un timer reserve a une difficulte, et tout
-- ce que le moteur sait declencher (emote, aura sur le joueur, mort d'un add,
-- compte a rebours, phase temporisee), plus un boss dont les capacites ne
-- tombent pas a heure fixe. Explicitement faux : aucun de ces npcIds n'existe
-- en jeu.

local _, ns = ...

ns.BossTimerData[99001] = {
    name    = "Conseil des Tests",
    kind    = "world",
    npcIds  = { 99002 },
    flavors = { vanilla = true, retail = true },
    zone    = "Terrain d'essai",

    phases = {
        { name = "Un" },
        { name = "Deux", trigger = "EMOTE", pattern = "rugit", alert = "Phase 2" },
        { name = "Trois", trigger = "PHASE", time = 30, alert = "Phase 3" },
    },

    timers = {
        { trigger = "PULL", time = 8, name = "Compte", countdown = 3, announce = true, bar = true, once = true },
        { trigger = "AURA", spellId = 99010, on = "player", name = "Marque", bar = false },
        { trigger = "AURA", spellId = 99011, on = "any", name = "Bombe", announce = true, bar = false },
        { trigger = "DEATH", npcId = 99020, name = "Add mort", bar = false },
        { trigger = "PHASE", phase = 2, time = 5, name = "Sort de phase 2", bar = true },
    },
}

ns.BossTimerData[99100] = {
    name    = "Gardien des Tests",
    kind    = "dungeon",
    flavors = { vanilla = true, retail = true },
    zone    = "Terrain d'essai",

    timers = {
        { trigger = "PULL", time = 20, name = "Normal seulement", difficulties = { 1 }, bar = true },
        { trigger = "PULL", time = 20, name = "Heroique seulement", difficulties = { 2 }, bar = true },
        { trigger = "PULL", time = 15, name = "Toutes difficultes", bar = true },
    },
}

-- Boss dont deux capacites sur trois ne tombent pas a heure fixe : la mesure ne
-- dit que le moment ou elles redeviennent possibles, pas celui ou elles
-- tombent. Elles portent `variable`, et c'est le cast observe qui fait foi.
ns.BossTimerData[99200] = {
    name    = "Imprevisible",
    kind    = "dungeon",
    flavors = { vanilla = true, retail = true },
    zone    = "Terrain d'essai",

    timers = {
        { trigger = "PULL", time = 10, spellId = 99210, name = "Coup de sang",
          variable = true, announce = true, bar = true, once = true },
        { trigger = "PULL", time = 10, spellId = 99211, name = "Salve",
          repeatInterval = 20, variable = true, bar = true },
        { trigger = "PULL", time = 10, spellId = 99212, name = "Certain",
          repeatInterval = 20, announce = true, bar = true },
    },
}
