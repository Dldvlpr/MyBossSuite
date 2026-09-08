-- Core/Alerts.lua
-- Alertes plein ecran : gros texte + son, entierement parametrables et
-- deplacables comme n'importe quel autre element de l'addon.
--
-- Factorise ici plutot que dans chaque module : le kick et le "MOVE" ont
-- exactement les memes besoins (texte, couleur, taille, duree, flash, son), et
-- deux implementations divergent toujours au bout de trois patchs.
--
-- Regle : le son ne doit jamais pouvoir casser le visuel. Un id de SOUNDKIT
-- absent d'un vieux client ou un fichier introuvable passent par pcall dans
-- Compat, et l'alerte s'affiche quand meme.

local _, ns = ...

local Alerts = {}
ns.Alerts = Alerts

Alerts.registry = {}   -- [key] = { anchorKey, label, getConfig, display }

--------------------------------------------------------------------------------
-- Configuration par defaut
--------------------------------------------------------------------------------

local ALERT_DEFAULTS = {
    visual    = true,
    sound     = true,
    text      = "!",
    color     = { 1, 0.82, 0.1 },
    fontSize  = 42,
    duration  = 2,
    flash     = true,
    soundName = "raidwarning",   -- preset, id de SOUNDKIT, ou chemin de fichier
    channel   = "Master",
    throttle  = 0.4,             -- anti-spam sonore, en secondes
}

ns.ALERT_DEFAULTS = ALERT_DEFAULTS

--- Table d'alerte complete, prete a etre posee dans les defaults d'un module.
function Alerts.MakeDefaults(overrides)
    local out = {}
    for k, v in pairs(ALERT_DEFAULTS) do
        if type(v) == "table" then
            local copy = {}
            for i = 1, #v do copy[i] = v[i] end
            out[k] = copy
        else
            out[k] = v
        end
    end
    for k, v in pairs(overrides or {}) do out[k] = v end
    return out
end

--------------------------------------------------------------------------------
-- Police
--------------------------------------------------------------------------------
-- Le chemin en dur est un filet : sur un client normal on reprend la police du
-- theme, donc un client localise (russe, coreen) garde ses glyphes.

local FALLBACK_FONT = "Fonts\\FRIZQT__.TTF"

local function ThemeFont()
    local source = _G.GameFontNormalHuge or _G.GameFontNormal
    if source and source.GetFont then
        local path = source:GetFont()
        if path then return path end
    end
    return FALLBACK_FONT
end

--------------------------------------------------------------------------------
-- Flash plein ecran
--------------------------------------------------------------------------------
-- Un bandeau colore qui s'efface : c'est ce qui attrape l'oeil quand le regard
-- est ailleurs. Volontairement borne a 0.35 d'alpha — au-dela on ne voit plus
-- le jeu, ce qui est l'inverse du but.

local FLASH_ALPHA    = 0.35
local FLASH_DURATION = 0.45

local flash

local function GetFlash()
    if flash then return flash end

    flash = CreateFrame("Frame", nil, UIParent)
    flash:SetAllPoints(UIParent)
    flash:SetFrameStrata("BACKGROUND")
    flash:Hide()

    local texture = flash:CreateTexture(nil, "BACKGROUND")
    texture:SetAllPoints(flash)
    ns.SetSolidColor(texture, 1, 0, 0, 1)
    flash.texture = texture

    flash.alpha = 0
    flash:SetScript("OnUpdate", function(self, elapsed)
        self.alpha = self.alpha - elapsed * (FLASH_ALPHA / FLASH_DURATION)
        if self.alpha <= 0 then
            self.alpha = 0
            self:SetAlpha(0)
            self:Hide()
            return
        end
        self:SetAlpha(self.alpha)
    end)

    return flash
end

function Alerts:Flash(color)
    local frame = GetFlash()
    ns.SetSolidColor(frame.texture, color[1], color[2], color[3], 1)
    frame.alpha = FLASH_ALPHA
    frame:SetAlpha(FLASH_ALPHA)
    frame:Show()
end

--------------------------------------------------------------------------------
-- Affichage
--------------------------------------------------------------------------------

local FADE_DURATION = 0.35

local function CreateDisplay(entry)
    local display = CreateFrame("Frame", nil, UIParent)
    display:SetSize(260, 64)
    display:SetFrameStrata("HIGH")
    display:Hide()

    local icon = display:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("RIGHT", display, "LEFT", -6, 0)
    icon:SetSize(40, 40)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:Hide()
    display.icon = icon

    local text = display:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    text:SetPoint("CENTER", display, "CENTER", 0, 6)
    display.text = text

    local subtitle = display:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    subtitle:SetPoint("TOP", text, "BOTTOM", 0, -2)
    display.subtitle = subtitle

    display.alpha = 1
    display:SetScript("OnUpdate", function(self, elapsed)
        if self.sticky or not self.fadeAt then return end
        local now = GetTime()
        if now < self.fadeAt then return end
        local ratio = 1 - (now - self.fadeAt) / FADE_DURATION
        if ratio <= 0 then
            self.fadeAt = nil
            self:SetAlpha(1)
            Alerts:Hide(entry.key)
            return
        end
        self:SetAlpha(ratio)
    end)

    ns.Anchors:Register(display, entry.anchorKey, {
        label        = entry.label,
        defaultPoint = entry.defaultPoint,
        test         = function() Alerts:StartTest(entry.key) end,
    })

    return display
end

--- Declare une alerte parametrable.
-- opts.getConfig doit retourner la table `alert` du module (ou nil si le module
-- n'est pas encore initialise) : l'alerte reste affichable et deplacable meme
-- module eteint, avec les valeurs par defaut.
function Alerts:Register(key, opts)
    local entry = self.registry[key]
    if entry then return entry end

    entry = {
        key          = key,
        anchorKey    = opts.anchorKey or (key .. "_Display"),
        label        = opts.label or key,
        defaultPoint = opts.defaultPoint,
        getConfig    = opts.getConfig,
        defaults     = opts.defaults or ALERT_DEFAULTS,
        order        = opts.order or 100,
    }
    self.registry[key] = entry
    entry.display = CreateDisplay(entry)
    return entry
end

function Alerts:Get(key)
    return self.registry[key]
end

--- Ordre stable pour l'UI : sinon le panneau reorganise ses lignes a chaque
-- ouverture, au gre de `pairs`.
function Alerts:SortedKeys()
    local out = {}
    for key in pairs(self.registry) do out[#out + 1] = key end
    table.sort(out, function(a, b)
        local ea, eb = self.registry[a], self.registry[b]
        if ea.order ~= eb.order then return ea.order < eb.order end
        return a < b
    end)
    return out
end

function Alerts:GetConfig(key)
    local entry = self.registry[key]
    if not entry then return nil end
    local config = entry.getConfig and entry.getConfig()
    return config or entry.defaults
end

--- Ecrit un champ de configuration d'alerte (son, couleur, taille...).
-- Passe par le module proprietaire : la valeur atterrit dans le profil et
-- survit au /reload.
function Alerts:Set(key, field, value)
    local entry = self.registry[key]
    if not entry then return false end
    local config = entry.getConfig and entry.getConfig()
    if not config then return false end
    config[field] = value
    return true
end

--- Remet l'alerte a ses valeurs d'usine (celles declarees par son module).
function Alerts:Reset(key)
    local entry = self.registry[key]
    if not entry then return false end
    local config = entry.getConfig and entry.getConfig()
    if not config then return false end
    for k in pairs(config) do config[k] = nil end
    for k, v in pairs(entry.defaults) do
        if type(v) == "table" then
            local copy = {}
            for i = 1, #v do copy[i] = v[i] end
            config[k] = copy
        else
            config[k] = v
        end
    end
    return true
end

local function Value(config, field)
    local value = config[field]
    if value == nil then return ALERT_DEFAULTS[field] end
    return value
end

--------------------------------------------------------------------------------
-- Son
--------------------------------------------------------------------------------

local lastSound = {}

function Alerts:PlaySound(key, force)
    local config = self:GetConfig(key)
    if not config then return false end
    if not force and Value(config, "sound") == false then return false end

    local now = GetTime()
    local throttle = tonumber(Value(config, "throttle")) or 0
    if not force and lastSound[key] and now - lastSound[key] < throttle then
        return false
    end
    lastSound[key] = now

    return ns.PlayAlertSound(Value(config, "soundName"), Value(config, "channel"))
end

--------------------------------------------------------------------------------
-- Affichage / masquage
--------------------------------------------------------------------------------

--- Declenche l'alerte `key`.
-- opts : text, subtitle, icon, color, duration, sticky (reste jusqu'a Hide),
--        silent (visuel seul), quiet (pas de flash).
function Alerts:Show(key, opts)
    local entry = self.registry[key]
    if not entry then return false end
    opts = opts or {}

    local config = self:GetConfig(key)
    local shown = false

    if Value(config, "visual") ~= false then
        local display = entry.display
        local color = opts.color or Value(config, "color")
        local size  = tonumber(Value(config, "fontSize")) or ALERT_DEFAULTS.fontSize

        display.text:SetFont(ThemeFont(), size, "OUTLINE")
        display.text:SetText(opts.text or Value(config, "text"))
        display.text:SetTextColor(color[1], color[2], color[3])

        if opts.subtitle and opts.subtitle ~= "" then
            display.subtitle:SetText(opts.subtitle)
            display.subtitle:Show()
        else
            display.subtitle:SetText("")
            display.subtitle:Hide()
        end

        if opts.icon then
            display.icon:SetTexture(opts.icon)
            display.icon:SetSize(size, size)
            display.icon:Show()
        else
            display.icon:Hide()
        end

        display:SetSize(math.max(200, size * 5), size + 26)
        display:SetAlpha(1)
        display.sticky = opts.sticky and true or false
        display.isTest = opts.isTest and true or false
        display.activeText = opts.text or Value(config, "text")
        display:Show()

        local duration = tonumber(opts.duration) or tonumber(Value(config, "duration")) or 2
        ns.Scheduler:Cancel("Alerts_" .. key)
        if opts.sticky then
            display.fadeAt = nil
        else
            -- Le fondu est pilote par OnUpdate, le Scheduler n'est la que comme
            -- filet si la frame n'a jamais recu d'OnUpdate (frame masquee).
            display.fadeAt = GetTime() + math.max(duration - FADE_DURATION, 0.05)
            ns.Scheduler:Schedule("Alerts_" .. key, duration + FADE_DURATION, function()
                Alerts:Hide(key)
            end)
        end

        if Value(config, "flash") ~= false and not opts.quiet then
            self:Flash(color)
        end

        shown = true
    end

    if not opts.silent and self:PlaySound(key) then shown = true end

    ns.EventBus:Fire("ALERT_SHOWN", key, opts)
    return shown
end

function Alerts:Hide(key)
    local entry = self.registry[key]
    if not entry then return end
    ns.Scheduler:Cancel("Alerts_" .. key)
    local display = entry.display
    display.fadeAt = nil
    display.sticky = false
    display.isTest = false
    display.activeText = nil
    display:SetAlpha(1)
    if display.mbsForcedShow or display.mbsUnlocked then return end
    display:Hide()
end

function Alerts:IsShown(key)
    local entry = self.registry[key]
    return entry ~= nil and entry.display.activeText ~= nil
end

function Alerts:HideAll()
    for key in pairs(self.registry) do self:Hide(key) end
end

--------------------------------------------------------------------------------
-- Apercu et mode test
--------------------------------------------------------------------------------

--- Joue l'alerte telle qu'elle sortira en jeu, son compris et sans throttle :
-- c'est le seul moyen de regler un son sans attendre le prochain pull.
function Alerts:Preview(key)
    local entry = self.registry[key]
    if not entry then return false end
    self:PlaySound(key, true)
    self:Show(key, { silent = true, subtitle = "apercu" })
    return true
end

--- Alerte persistante pendant `/mbs test` : sans elle, impossible de placer la
-- frame, l'alerte etant par nature fugace.
function Alerts:StartTest(key)
    local config = self:GetConfig(key)
    self:Show(key, {
        sticky   = true,
        isTest   = true,
        silent   = true,
        quiet    = true,
        subtitle = self.registry[key].label,
        text     = Value(config, "text"),
    })
end

function Alerts:StopTest()
    for key, entry in pairs(self.registry) do
        if entry.display.isTest then self:Hide(key) end
    end
end

ns.EventBus:On("TEST_STOPPED", function()
    Alerts:StopTest()
end)
