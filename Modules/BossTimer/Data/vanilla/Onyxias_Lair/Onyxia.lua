-- Onyxia — Classic Era (npcId 10184)
--
-- ATTENTION : timings PROVISOIRES. Ce fichier sert de reference de format ; il
-- doit etre regenere par `tools/wcl-ingest` (mediane sur N logs, partition
-- correspondant a ce flavor) avant tout usage serieux. Les entrees non encore
-- mesurees portent `provisional = true`.
--
-- Les phases, elles, ne sont pas des timings : Onyxia decolle a 65 % et se
-- repose a 40 %, c'est la mecanique du combat, pas une mesure.
--
-- Cle = npcId, jamais le nom : le nom du boss est localise (clients FR/DE/RU),
-- indexer dessus casse des qu'on sort d'un client EN. `name` est un champ
-- d'affichage uniquement.

local _, ns = ...

ns.BossTimerData[10184] = {
    name        = "Onyxia",       -- display only
    kind        = "raid",
    encounterId = 1084,           -- retail / classic recent
    instanceId  = 249,
    flavors     = { vanilla = true },
    zone        = "Onyxia's Lair",
    provisional = true,

    phases = {
        { name = "Sol" },
        { name = "Vol",  trigger = "HEALTH", threshold = 0.65, alert = "Phase 2", testTime = 20 },
        { name = "Sol",  trigger = "HEALTH", threshold = 0.40, alert = "Phase 3", testTime = 40 },
    },

    timers = {
        -- Phase 1 : Flame Breath, cadence mesuree a affiner.
        {
            trigger        = "PULL",
            time           = 12,
            spellId        = 17086,
            name           = "Flame Breath",
            phase          = 1,
            repeatInterval = 25,
            warnBefore     = 3,
            bar            = true,
            variable       = true,
            provisional    = true,
        },
        -- Phase 2 : Fireball Volley au cast, Deep Breath annonce quand il part.
        {
            trigger     = "CAST",
            spellId     = 18435,
            name        = "Fireball Volley",
            phase       = 2,
            warnBefore  = 3,
            bar         = true,
            testTime    = 25,
            provisional = true,
        },
        {
            trigger     = "CAST",
            spellId     = 18431,
            castStart   = true,
            name        = "Deep Breath",
            phase       = 2,
            announce    = "DEEP BREATH",
            flash       = true,
            bar         = false,
            testTime    = 30,
            provisional = true,
        },
        -- Phase 3 : Flame Breath reprend, relatif a l'atterrissage.
        {
            trigger        = "PHASE",
            phase          = 3,
            time           = 10,
            spellId        = 17086,
            name           = "Flame Breath",
            repeatInterval = 25,
            warnBefore     = 3,
            bar            = true,
            variable       = true,
            provisional    = true,
        },
        {
            trigger     = "AURA",
            spellId     = 18431,
            on          = "player",
            name        = "Deep Breath",
            phase       = 2,
            bar         = false,
            testTime    = 34,
            provisional = true,
        },
    },
}

-- Alias retail / Cata+ : ENCOUNTER_START livre un encounterID, pas un npcId.
ns.BossTimerEncounter[1084] = 10184
