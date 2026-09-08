-- tests/fixtures/bossmods/DBM-TestBoss/TestBoss.lua
--
-- Faux module DBM, ecrit pour la suite de tests. Il ne reproduit AUCUN contenu
-- de DBM : ni leurs timings, ni leurs libelles, ni leur code. Il reproduit les
-- FORMES d'ecriture que le parseur doit savoir lire, et celles qu'il doit
-- savoir refuser :
--   * un CD simple, un intervalle en fourchette ("20-30" = non deterministe) ;
--   * un temps d'incantation negatif (= « prends celui du sort ») a ecarter ;
--   * un timer de phase sans spellId, a ecarter ;
--   * un enrage, qui est le seul vrai delai depuis le pull ;
--   * des :Start() avec une expression, qui ne sont pas des cadences.
-- Les spellIds sont ceux des fixtures du depot (99xxx), donc faux en jeu.

local mod = DBM:NewMod("TestBoss", "DBM-TestBoss", 1, 249)
local L   = mod:GetLocalizedStrings()

mod:SetRevision("20260908000000")
mod:SetCreatureID(99001, 99002)
mod:SetEncounterID(4242)

mod:RegisterCombat("combat")
mod:RegisterEventsInCombat(
    "SPELL_CAST_START 99210",
    "SPELL_CAST_SUCCESS 99211",
    "SPELL_AURA_APPLIED 99212"
)

local warnBreath     = mod:NewSpellAnnounce(99210, 3)
local specWarnVolley = mod:NewSpecialWarningDodge(99211, nil, nil, nil, 2, 2)

local timerBreathCD  = mod:NewCDTimer(25.5, 99210, nil, nil, nil, 3)
local timerVolley    = mod:NewNextTimer("20-30", 99211)
local timerCast      = mod:NewCastTimer(-4, 99212)
local timerPhase     = mod:NewPhaseTimer(45)
local timerBerserk   = mod:NewBerserkTimer(600)
local timerNoSpell   = mod:NewTimer(15, "TimerAdds", 136116)

function mod:OnCombatStart(delay)
    timerBreathCD:Start(12 - delay)
    timerVolley:Start(20)
    timerBerserk:Start()
end

function mod:SPELL_CAST_START(args)
    if args.spellId == 99210 then
        warnBreath:Show()
        timerBreathCD:Start(18.5)
    end
end
