-- tests/fixtures/BossData.lua
-- Rencontres synthetiques pour la suite headless : un world boss a deux npcIds
-- (conseil), un boss de donjon avec un timer reserve a une difficulte, un boss
-- dont les sorts n'ont pas d'horaire, et tout ce que le moteur sait declencher
-- (emote, aura sur le joueur, mort d'un add, compte a rebours, phase
-- temporisee). Explicitement faux : aucun de ces npcIds n'existe en jeu.

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

-- Un boss dont rien ne se prevoit : le premier sort n'a pas d'heure du tout
-- (`CAST`, il s'affiche quand le boss le lance), le second en a une, mais
-- mesuree si large qu'elle ne promet rien (`variable`).
ns.BossTimerData[99200] = {
    name    = "Incantateur des Tests",
    kind    = "dungeon",
    flavors = { vanilla = true, retail = true },
    zone    = "Terrain d'essai",

    timers = {
        { trigger = "CAST", spellId = 99210, castStart = true, castTime = 5,
          name = "Incantation", bar = true },
        { trigger = "PULL", time = 20, spellId = 99211, name = "Aleatoire",
          variable = true, bar = true },
    },
}
