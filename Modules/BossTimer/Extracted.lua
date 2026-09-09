-- Modules/BossTimer/Extracted.lua
-- Data extraite localement des boss mods installes, via tools/bossmod-extract.
--
-- Le generateur n'ecrit RIEN dans ce depot : il produit un addon compagnon,
-- `MyBossSuite_BossModData`, a cote du client. Ce fichier-ci est le seul point
-- de contact, et il ne fait qu'une chose : lire la table globale que ce
-- compagnon depose, et verser dans `ns.BossTimerData` les rencontres pour
-- lesquelles le depot n'a rien.
--
-- Pourquoi une table globale plutot que le namespace de l'addon : deux addons
-- distincts ne partagent pas de `ns`, et l'ordre de chargement entre eux n'est
-- pas garanti. Un global lu au demarrage du module marche dans les deux sens,
-- et l'absence du compagnon ne demande aucun test particulier — la table
-- n'existe simplement pas.
--
-- **Preseance**, du plus sur au moins sur :
--
--   1. la data du depot     — mesuree (tools/wcl-ingest), ou ecrite a la main
--   2. la data extraite     — ce fichier : les chiffres de DBM/BigWigs
--   3. le pont (Bridge.lua) — DBM/BigWigs qui tournent, en direct
--
-- Une entree extraite ne remplace donc JAMAIS une entree du depot, meme
-- provisoire : celle du depot a ete relue par quelqu'un, celle-ci non. Et une
-- rencontre couverte ici fait taire le pont pour ce combat, puisqu'elle devient
-- une rencontre « avec data » — ce qui est le bon arbitrage : une timeline
-- complete vaut mieux qu'un flux de barres.

local _, ns = ...

local Extracted = {}
ns.BossTimerExtracted = Extracted

Extracted.loaded  = 0     -- rencontres versees
Extracted.skipped = 0     -- rencontres ignorees, le depot en avait deja
Extracted.flavor  = nil   -- flavor declare par le compagnon
Extracted.stamp   = nil   -- horodatage de generation

--- Le compagnon a-t-il ete genere pour ce client ?
-- Charger de la data vanilla sur un client retail donnerait des timings faux
-- avec l'air d'etre justes. Le compagnon declare son flavor, on le verifie.
function Extracted:Matches(payload)
    local flavor = payload and payload.flavor
    if not flavor then return true end   -- compagnon ancien : on laisse passer
    return flavor == ns.flavor
end

function Extracted:Load()
    self.loaded, self.skipped = 0, 0
    self.flavor, self.stamp = nil, nil

    local payload = _G.MyBossSuiteBossModData
    if type(payload) ~= "table" or type(payload.data) ~= "table" then return 0 end

    self.flavor, self.stamp = payload.flavor, payload.generated

    if not self:Matches(payload) then
        ns.Print(("data boss mod extraite pour %s, client %s : ignoree.")
            :format(tostring(payload.flavor), tostring(ns.flavor)))
        return 0
    end

    for npcId, def in pairs(payload.data) do
        if type(npcId) == "number" and type(def) == "table" then
            if ns.BossTimerData[npcId] then
                self.skipped = self.skipped + 1
            else
                def.extracted = true
                ns.BossTimerData[npcId] = def
                self.loaded = self.loaded + 1
            end
        end
    end

    -- Les alias encounterID -> npcId suivent la meme regle : jamais par-dessus
    -- un alias du depot.
    if type(payload.encounter) == "table" then
        for encounterId, npcId in pairs(payload.encounter) do
            if type(encounterId) == "number" and ns.BossTimerData[npcId]
                and not ns.BossTimerEncounter[encounterId] then
                ns.BossTimerEncounter[encounterId] = npcId
            end
        end
    end

    ns.Debug("data extraite :", self.loaded, "chargee(s),", self.skipped, "ignoree(s)")
    return self.loaded
end

--- Retire ce qui a ete verse. Appele quand le module s'eteint : sans ca, un
-- rechargement doublerait les entrees ou figerait une data d'un profil a
-- l'autre.
function Extracted:Unload()
    for npcId, def in pairs(ns.BossTimerData) do
        if type(def) == "table" and def.extracted then
            ns.BossTimerData[npcId] = nil
            for encounterId, target in pairs(ns.BossTimerEncounter) do
                if target == npcId then ns.BossTimerEncounter[encounterId] = nil end
            end
        end
    end
    self.loaded, self.skipped = 0, 0
end

function Extracted:StatusLine()
    if not _G.MyBossSuiteBossModData then
        return "data boss mod extraite : absente (voir tools/bossmod-extract)"
    end
    if self.flavor and self.flavor ~= ns.flavor then
        return ("data boss mod extraite : |cffff5555generee pour %s|r, ignoree sur %s")
            :format(tostring(self.flavor), tostring(ns.flavor))
    end
    return ("data boss mod extraite : %d rencontre(s), %d deja couverte(s) par le depot%s")
        :format(self.loaded, self.skipped,
            self.stamp and ("   (" .. tostring(self.stamp) .. ")") or "")
end
