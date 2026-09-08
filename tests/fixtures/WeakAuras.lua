-- Fixture pour tests/test_wa_extract.py.
--
-- Reproduit ce qu'un vrai WeakAuras.lua contient et qui casse un parseur naif :
-- les deux schemas de trigger (l'ancien `trigger`, le nouveau `triggers[n]`),
-- des cles numeriques, des chaines a echappements, des nombres negatifs et en
-- notation scientifique, des commentaires Lua, et du code utilisateur stocke
-- comme une chaine (avec des accolades et des guillemets dedans).

WeakAurasSaved = {
    ["dbVersion"] = 62,
    ["displays"] = {
        -- Nouveau schema : triggers[n].trigger
        ["Deep Breath"] = {
            ["id"] = "Deep Breath",
            ["regionType"] = "icon",
            ["xOffset"] = -120.5,
            ["alpha"] = 1e0,
            ["triggers"] = {
                [1] = {
                    ["trigger"] = {
                        ["type"] = "EVENT",
                        ["event"] = "Combat Log",
                        ["subeventPrefix"] = "SPELL",
                        ["subeventSuffix"] = "_CAST_START",
                        ["spellIds"] = { 18431 },
                        ["use_sourceGUID"] = false,
                    },
                },
                ["activeTriggerMode"] = -10,
            },
        },
        -- Ancien schema : trigger a plat
        ["Flame Breath"] = {
            ["id"] = "Flame Breath",
            ["trigger"] = {
                ["type"] = "EVENT",
                ["event"] = "COMBAT_LOG_EVENT_UNFILTERED",
                ["subeventSuffix"] = "_CAST_SUCCESS",
                ["spellIds"] = { 17086, 18435 },
            },
            ["customText"] = "function() return \"P1 : \" .. { } end",
        },
        -- Wrapper DBM/BigWigs : aucune duree propre, rien a extraire
        ["Onyxia Pack"] = {
            ["id"] = "Onyxia Pack",
            ["triggers"] = {
                [1] = { ["trigger"] = { ["type"] = "BOSS_MOD", ["event"] = "BossMod Timer" } },
            },
        },
        -- Trigger EVENT mais pas sur le combat log : inexploitable ici
        ["Vie du groupe"] = {
            ["id"] = "Vie du groupe",
            ["triggers"] = {
                [1] = { ["trigger"] = { ["type"] = "EVENT", ["event"] = "Health" } },
            },
        },
    },
}
