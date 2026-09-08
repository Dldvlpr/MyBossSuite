-- Herod — Classic Era (npcId 3975), Monastere Ecarlate (Armurerie).
--
-- Reference de format pour une rencontre `kind = "dungeon"` : combat a cinq,
-- pas de timing depuis le pull, tout part du combat log. Whirlwind se voit au
-- SPELL_CAST_START (c'est le moment de s'ecarter), et l'enrage a 30 % passe par
-- l'aura Frenzy sur le boss. Les spellIds restent a confirmer par `wcl-ingest`.

local _, ns = ...

ns.BossTimerData[3975] = {
    name        = "Herod",
    kind        = "dungeon",
    instanceId  = 189,
    flavors     = { vanilla = true },
    zone        = "Scarlet Monastery",
    provisional = true,

    phases = {
        { name = "Combat" },
        { name = "Frenzy", trigger = "AURA", spellId = 8269, alert = "ENRAGE", testTime = 20 },
    },

    timers = {
        {
            trigger     = "CAST",
            spellId     = 8989,
            castStart   = true,
            name        = "Whirlwind",
            announce    = "WHIRLWIND - ECARTE-TOI",
            flash       = true,
            bar         = false,
            testTime    = 8,
            provisional = true,
        },
    },
}
