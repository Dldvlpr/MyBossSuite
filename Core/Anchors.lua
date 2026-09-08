-- Core/Anchors.lua
-- Positionnement transversal : chaque element affichable est deplacable et
-- ancrable independamment, avec un mode unlock et un mode test.
--
-- Points corriges par rapport a une sauvegarde naive :
--   * relativeTo conserve  -> sinon la position sauvee est fausse des qu'une
--     frame est ancree ailleurs qu'a UIParent ;
--   * scale sauvegarde     -> sinon un changement de resolution decale tout ;
--   * SetClampedToScreen   -> sinon on perd une frame hors ecran sans moyen de
--     la recuperer.

local _, ns = ...

local Anchors = {}
ns.Anchors = Anchors

Anchors.registry = {}   -- [anchorKey] = { frame = f, label = s, test = fn }

--------------------------------------------------------------------------------
-- Bordure (4 textures : evite l'API Backdrop, divergente entre flavors)
--------------------------------------------------------------------------------

-- SetColorTexture (retail / classic recent) vs SetTexture(r,g,b,a) (vieux clients).
function ns.SetSolidColor(texture, r, g, b, a)
    if texture.SetColorTexture then
        texture:SetColorTexture(r, g, b, a or 1)
    else
        texture:SetTexture(r, g, b, a or 1)
    end
end

function ns.CreateBorder(frame, thickness, r, g, b, a)
    thickness = thickness or 1
    local edges = {}
    for i = 1, 4 do
        local tex = frame:CreateTexture(nil, "OVERLAY")
        ns.SetSolidColor(tex, r or 1, g or 1, b or 1, a or 1)
        edges[i] = tex
    end
    edges[1]:SetPoint("TOPLEFT"); edges[1]:SetPoint("TOPRIGHT"); edges[1]:SetHeight(thickness)
    edges[2]:SetPoint("BOTTOMLEFT"); edges[2]:SetPoint("BOTTOMRIGHT"); edges[2]:SetHeight(thickness)
    edges[3]:SetPoint("TOPLEFT"); edges[3]:SetPoint("BOTTOMLEFT"); edges[3]:SetWidth(thickness)
    edges[4]:SetPoint("TOPRIGHT"); edges[4]:SetPoint("BOTTOMRIGHT"); edges[4]:SetWidth(thickness)

    local border = { edges = edges }

    function border:SetColor(cr, cg, cb, ca)
        for i = 1, 4 do
            ns.SetSolidColor(edges[i], cr, cg, cb, ca or 1)
        end
    end

    function border:Show() for i = 1, 4 do edges[i]:Show() end end
    function border:Hide() for i = 1, 4 do edges[i]:Hide() end end

    return border
end

--------------------------------------------------------------------------------
-- AnchorMixin
--------------------------------------------------------------------------------

local AnchorMixin = {}
ns.AnchorMixin = AnchorMixin

function AnchorMixin:EnablePositioning()
    self:SetMovable(true)
    self:SetClampedToScreen(true)
    self:RegisterForDrag("LeftButton")
    self:SetScript("OnDragStart", function(f)
        if not f.mbsUnlocked then return end
        f:StartMoving()
    end)
    self:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        f:SaveAnchor()
    end)
    self:SetScript("OnMouseWheel", function(f, delta)
        if not f.mbsUnlocked then return end
        local scale = math.max(0.4, math.min(3, (f:GetScale() or 1) + delta * 0.05))
        f:SetScale(scale)
        f:SaveAnchor()
        if f.mbsOverlay then f.mbsOverlay.label:SetText(f:GetAnchorLabel()) end
    end)
    self:SetAnchorMouse(false)
end

-- Nom prefixe volontairement : les methodes du mixin sont copiees sur une vraie
-- Frame, il ne faut jamais risquer d'ecraser une methode native.
function AnchorMixin:SetAnchorMouse(enabled)
    self:EnableMouse(enabled and true or false)
    self:EnableMouseWheel(enabled and true or false)
end

function AnchorMixin:GetAnchorLabel()
    local scale = self:GetScale() or 1
    return ("%s  |cffaaaaaa(%.0f%%)|r"):format(self.anchorKey, scale * 100)
end

function AnchorMixin:SaveAnchor()
    local point, relTo, relPoint, x, y = self:GetPoint()
    if not point then return end
    ns.db.anchors[self.anchorKey] = {
        point    = point,
        relTo    = (relTo and relTo.GetName and relTo:GetName()) or "UIParent",
        relPoint = relPoint,
        x        = x,
        y        = y,
        scale    = self:GetScale(),
    }
end

function AnchorMixin:LoadAnchor()
    local saved = ns.db and ns.db.anchors[self.anchorKey]
    self:ClearAllPoints()
    if saved then
        local parent = _G[saved.relTo] or UIParent
        self:SetScale(saved.scale or 1)
        self:SetPoint(saved.point, parent, saved.relPoint, saved.x, saved.y)
    else
        self:SetScale(1)
        local d = self.defaultPoint
        if d then
            self:SetPoint(d[1], _G[d[2]] or UIParent, d[3], d[4], d[5])
        else
            self:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
    end
end

function AnchorMixin:ResetAnchor()
    if ns.db then ns.db.anchors[self.anchorKey] = nil end
    self:LoadAnchor()
end

--------------------------------------------------------------------------------
-- Registre
--------------------------------------------------------------------------------

--- Rend `frame` deplacable et la declare sous `anchorKey`.
-- opts.defaultPoint = { point, relToName, relPoint, x, y }
-- opts.test         = fonction appelee par /mbs test pour peupler la frame
-- opts.label        = libelle lisible affiche en mode unlock
function Anchors:Register(frame, anchorKey, opts)
    opts = opts or {}
    frame.anchorKey    = anchorKey
    frame.defaultPoint = opts.defaultPoint

    for name, fn in pairs(AnchorMixin) do
        if frame[name] == nil then frame[name] = fn end
    end

    frame:EnablePositioning()
    frame:LoadAnchor()

    self.registry[anchorKey] = {
        frame = frame,
        label = opts.label or anchorKey,
        test  = opts.test,
    }

    if self.unlocked then self:ApplyUnlock(frame, true) end
    return frame
end

function Anchors:Unregister(anchorKey)
    local entry = self.registry[anchorKey]
    if entry then
        self:ApplyUnlock(entry.frame, false)
        self.registry[anchorKey] = nil
    end
end

function Anchors:Get(anchorKey)
    local entry = self.registry[anchorKey]
    return entry and entry.frame
end

--- Un seul point de verite pour choisir la frame qui recoit une alerte.
-- Override seulement les cas qui genent : pas de config manuelle systematique.
function ns:ResolveAnchorKey(spellId)
    if spellId then
        local specific = "BossTimer_Alert_" .. spellId
        if ns.db and ns.db.anchors[specific] then return specific end
    end
    return "BossTimer_GenericBar"
end

--------------------------------------------------------------------------------
-- Mode unlock
--------------------------------------------------------------------------------

local function CreateOverlay(frame)
    local overlay = CreateFrame("Frame", nil, frame)
    overlay:SetAllPoints(frame)
    overlay:SetFrameLevel(frame:GetFrameLevel() + 10)

    local bg = overlay:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(overlay)
    ns.SetSolidColor(bg, 0, 0.6, 1, 0.15)

    overlay.border = ns.CreateBorder(overlay, 1, 0.2, 0.8, 1, 0.9)

    local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("BOTTOM", overlay, "TOP", 0, 2)
    overlay.label = label

    local reset = CreateFrame("Button", nil, overlay, "UIPanelButtonTemplate")
    reset:SetSize(60, 18)
    reset:SetPoint("TOP", overlay, "BOTTOM", 0, -2)
    reset:SetText("Reset")
    reset:SetScript("OnClick", function()
        frame:ResetAnchor()
        label:SetText(frame:GetAnchorLabel())
    end)
    overlay.reset = reset

    return overlay
end

function Anchors:ApplyUnlock(frame, unlocked)
    frame.mbsUnlocked = unlocked
    frame:SetAnchorMouse(unlocked)

    if unlocked then
        if not frame.mbsOverlay then
            frame.mbsOverlay = CreateOverlay(frame)
        end
        frame.mbsOverlay.label:SetText(frame:GetAnchorLabel())
        frame.mbsOverlay:Show()
        if not frame:IsShown() then
            frame.mbsForcedShow = true
            frame:Show()
        end
    else
        if frame.mbsOverlay then frame.mbsOverlay:Hide() end
        if frame.mbsForcedShow then
            frame.mbsForcedShow = nil
            frame:Hide()
        end
    end
end

function Anchors:Unlock()
    self.unlocked = true
    if ns.db then ns.db.locked = false end
    for _, entry in pairs(self.registry) do
        self:ApplyUnlock(entry.frame, true)
    end
    ns.Print("mode unlock actif. Glisser pour deplacer, molette pour redimensionner, /mbs lock pour verrouiller.")
end

function Anchors:Lock()
    self.unlocked = false
    if ns.db then ns.db.locked = true end
    for _, entry in pairs(self.registry) do
        self:ApplyUnlock(entry.frame, false)
    end
end

function Anchors:ToggleUnlock()
    if self.unlocked then self:Lock() else self:Unlock() end
end

function Anchors:ResetAll()
    for _, entry in pairs(self.registry) do
        entry.frame:ResetAnchor()
        if entry.frame.mbsOverlay then
            entry.frame.mbsOverlay.label:SetText(entry.frame:GetAnchorLabel())
        end
    end
    ns.Print("toutes les positions ont ete reinitialisees.")
end

function Anchors:ReloadAll()
    for _, entry in pairs(self.registry) do
        entry.frame:LoadAnchor()
    end
end

--------------------------------------------------------------------------------
-- Mode test
--------------------------------------------------------------------------------
-- Indispensable, pas optionnel : sans lui on ne peut pas placer ses bars hors
-- raid.

function Anchors:Test(anchorKey)
    local count = 0
    for key, entry in pairs(self.registry) do
        if (not anchorKey or key == anchorKey) and entry.test then
            entry.test(entry.frame)
            count = count + 1
        end
    end
    if count == 0 then
        ns.Print("aucun element de test pour " .. (anchorKey or "les ancres actives")
            .. " (module desactive ?)")
    end
    return count
end

ns.EventBus:On("PROFILE_CHANGED", function()
    Anchors:ReloadAll()
end)
