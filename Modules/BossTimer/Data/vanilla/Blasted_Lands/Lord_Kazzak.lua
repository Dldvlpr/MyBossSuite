-- Lord Kazzak — Classic Era (npcId 12397), world boss des Terres Foudroyees.
--
-- Reference de format pour une rencontre `kind = "world"` : pas
-- d'ENCOUNTER_START, pas d'unite boss1, un boss que d'autres groupes ont pu
-- engager avant toi. L'engage se fait sur le premier evenement du combat log
-- ou Kazzak agit ou encaisse ; la fin de combat sur sa mort, sur l'absence de
-- combat du groupe, ou sur son inactivite (reset).
--
-- Le seul timing en dur est l'enrage a 3 minutes (Supreme), qui est une
-- mecanique connue et non une mesure. Le reste est declenche par le combat
-- log, sans timing invente. Les spellIds restent a confirmer par `wcl-ingest`.

local _, ns = ...

ns.BossTimerData[12397] = {
    name        = "Lord Kazzak",
    kind        = "world",
    flavors     = { vanilla = true },
    zone        = "Blasted Lands",
    provisional = true,

    timers = {
        {
            trigger    = "PULL",
            time       = 180,
            name       = "Supreme (enrage)",
            once       = true,
            announce   = "ENRAGE",
            flash      = true,
            warnBefore = 10,
            countdown  = 5,
            color      = { 0.9, 0.2, 0.2 },
            bar        = true,
        },
        {
            trigger     = "AURA",
            spellId     = 21056,
            on          = "player",
            name        = "Mark of Kazzak",
            bar         = false,
            provisional = true,
        },
        {
            trigger     = "AURA",
            spellId     = 21063,
            on          = "player",
            name        = "Twisted Reflection",
            bar         = false,
            provisional = true,
        },
    },
}
