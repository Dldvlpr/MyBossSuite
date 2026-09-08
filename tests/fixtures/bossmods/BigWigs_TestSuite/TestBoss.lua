-- tests/fixtures/bossmods/BigWigs_TestSuite/TestBoss.lua
--
-- Faux module BigWigs, meme principe que le DBM voisin : les formes, pas le
-- contenu. Ce qu'il faut savoir lire ici est plus dur que chez DBM — les
-- durees ne sont pas au top-level, et la cle d'une barre est souvent
-- `args.spellId`, donc connue seulement via le self:Log qui a enregistre le
-- handler. Il y a aussi une duree conditionnelle, qui n'est pas un nombre et
-- doit etre ecartee au lieu d'etre devinee.

local mod, CL = BigWigs:NewBoss("Test Boss", 249, 4242)
if not mod then return end

mod:RegisterEnableMob(99001, 99002)
mod.engageId    = 4242
mod.respawnTime = 30

function mod:GetOptions()
    return { 99210, 99211, { 99212, "SAY" } }
end

function mod:OnBossEnable()
    self:Log("SPELL_CAST_START", "Breath", 99210)
    self:Log("SPELL_CAST_SUCCESS", "Volley", 99211, 99213)
    self:Death("Win", 99001)
end

function mod:OnEngage()
    self:CDBar(99210, 12)
    self:Bar(99211, 20.5)
    self:Berserk(600)
end

function mod:Breath(args)
    self:Message2(args.spellId, "red")
    self:CDBar(args.spellId, self:Mythic() and 22 or 26)
end

function mod:Volley(args)
    self:Bar(args.spellId, 20.5)
end
