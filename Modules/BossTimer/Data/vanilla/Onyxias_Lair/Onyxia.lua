-- Onyxia — Classic Era (npcId 10184)
--
-- ATTENTION : timings PROVISOIRES. Ce fichier sert de reference de format ; il
-- doit etre regenere par `tools/wcl-ingest` (mediane sur N logs, partition
-- correspondant a ce flavor) avant tout usage serieux. Les entrees non encore
-- mesurees portent `provisional = true`.
--
-- Cle = npcId, jamais le nom : le nom du boss est localise (clients FR/DE/RU),
-- indexer dessus casse des qu'on sort d'un client EN. `name` est un champ
-- d'affichage uniquement.

local _, ns = ...

ns.BossTimerData[10184] = {
    name        = "Onyxia",       -- display only
    encounterId = 1084,           -- retail / classic recent
    flavors     = { vanilla = true },
    zone        = "Onyxia's Lair",
    provisional = true,

    timers = {
        {
            trigger        = "PULL",
            time           = 12,
            spellId        = 17086,
            name           = "Flame Breath",
            repeatInterval = 25,
            warnBefore     = 3,
            bar            = true,
            variable       = true,
            provisional    = true,
        },
        {
            trigger     = "CAST",
            spellId     = 18435,
            name        = "Fireball Volley",
            warnBefore  = 3,
            bar         = true,
            testTime    = 10,
            provisional = true,
        },
        {
            trigger   = "HEALTH",
            threshold = 0.65,
            name      = "Phase 2 - Deep Breath",
            once      = true,
            bar       = true,
            testTime  = 20,
        },
    },
}

-- Alias retail / Cata+ : ENCOUNTER_START livre un encounterID, pas un npcId.
ns.BossTimerEncounter[1084] = 10184
