-- Core/Bars.lua
-- Widget de barre + conteneur ancrable, partage par tous les modules.
-- Un groupe = une ancre = une pile de barres triees par temps restant.

local _, ns = ...

local Bars = {}
ns.Bars = Bars

Bars.groups = {}

local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"

local DEFAULTS = {
    width   = 220,
    height  = 18,
    spacing = 2,
    growth  = "UP",     -- "UP" ou "DOWN"
    maxBars = 8,
}

--------------------------------------------------------------------------------
-- Formatage
--------------------------------------------------------------------------------

local function FormatTime(remaining)
    if remaining >= 60 then
        return ("%d:%02d"):format(math.floor(remaining / 60), math.floor(remaining % 60))
    elseif remaining >= 10 then
        return ("%.0f"):format(remaining)
    end
    return ("%.1f"):format(remaining)
end

--------------------------------------------------------------------------------
-- Barre
--------------------------------------------------------------------------------

local BarMixin = {}

function BarMixin:SetColor(r, g, b)
    self.bar:SetStatusBarColor(r, g, b)
    self.color = self.color or {}
    self.color[1], self.color[2], self.color[3] = r, g, b
end

function BarMixin:SetIcon(icon)
    if icon then
        self.icon:SetTexture(icon)
        self.icon:Show()
    else
        self.icon:Hide()
    end
end

--- Raccourcit (ou rallonge) la barre en cours sans reinitialiser sa duree
-- affichee : utilise par le parry haste du swing timer.
function BarMixin:SetRemaining(remaining)
    self.endTime = GetTime() + remaining
    if remaining > self.duration then self.duration = remaining end
end

function BarMixin:GetRemaining()
    return self.endTime - GetTime()
end

function BarMixin:Stop()
    self.group:StopBar(self.id)
end

--------------------------------------------------------------------------------
-- Groupe
--------------------------------------------------------------------------------

local GroupMixin = {}

local function CreateBar(group)
    local frame = CreateFrame("Frame", nil, group)
    frame:SetSize(group.config.width, group.config.height)

    local bar = CreateFrame("StatusBar", nil, frame)
    bar:SetAllPoints(frame)
    bar:SetStatusBarTexture(BAR_TEXTURE)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    frame.bar = bar

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(bar)
    ns.SetSolidColor(bg, 0, 0, 0, 0.6)

    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("RIGHT", frame, "LEFT", -2, 0)
    icon:SetSize(group.config.height, group.config.height)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    frame.icon = icon

    local label = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", bar, "LEFT", 4, 0)
    label:SetJustifyH("LEFT")
    frame.label = label

    local timeText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    timeText:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    timeText:SetJustifyH("RIGHT")
    frame.timeText = timeText

    label:SetPoint("RIGHT", timeText, "LEFT", -4, 0)

    for name, fn in pairs(BarMixin) do frame[name] = fn end
    frame.group = group

    return frame
end

function GroupMixin:Acquire()
    local bar = tremove(self.pool)
    if not bar then bar = CreateBar(self) end
    bar:Show()
    return bar
end

function GroupMixin:Release(bar)
    bar:Hide()
    bar:ClearAllPoints()
    bar.id = nil
    bar.onExpire = nil
    bar.expiredText = nil
    self.pool[#self.pool + 1] = bar
end

--- Demarre (ou redemarre) une barre identifiee par `id`.
-- opts : color = {r,g,b}, warnBefore, variable, onExpire, keepOnExpire,
--        expiredText (ce qu'affiche le chrono d'une barre gardee a zero)
function GroupMixin:StartBar(id, duration, text, icon, opts)
    opts = opts or {}
    -- Duree nulle : seule une barre gardee a zero a un sens (elle attend un
    -- evenement, pas la fin d'un decompte). Ailleurs c'est une erreur d'appel.
    if duration <= 0 and not opts.keepOnExpire then return nil end
    if duration < 0 then duration = 0 end

    local bar = self.active[id]
    if not bar then
        bar = self:Acquire()
        bar.id = id
        self.active[id] = bar
        self.order[#self.order + 1] = bar
    end

    bar.duration     = duration
    bar.endTime      = GetTime() + duration
    bar.text         = text or ""
    bar.variable     = opts.variable
    bar.warnBefore   = opts.warnBefore
    bar.warned       = false
    bar.onExpire     = opts.onExpire
    bar.keepOnExpire = opts.keepOnExpire
    bar.expiredText  = opts.expiredText

    -- Un timing incertain ne doit pas s'afficher comme un timing mesure.
    bar.label:SetText(bar.variable and ("~" .. bar.text) or bar.text)
    bar:SetIcon(icon)

    local color = opts.color or self.config.color or { 0.25, 0.55, 0.9 }
    bar:SetColor(color[1], color[2], color[3])
    bar.bar:SetAlpha(bar.variable and 0.65 or 1)

    self:Layout()
    self:Show()
    self:StartUpdater()
    return bar
end

function GroupMixin:GetBar(id)
    return self.active[id]
end

function GroupMixin:StopBar(id)
    local bar = self.active[id]
    if not bar then return end
    self.active[id] = nil
    for i = #self.order, 1, -1 do
        if self.order[i] == bar then tremove(self.order, i) end
    end
    self:Release(bar)
    self:Layout()
end

function GroupMixin:StopAll()
    for i = #self.order, 1, -1 do
        local bar = self.order[i]
        self.active[bar.id] = nil
        self.order[i] = nil
        self:Release(bar)
    end
    self:StopUpdater()
    if not self.mbsForcedShow and not self.mbsUnlocked then self:Hide() end
    self:Layout()
end

function GroupMixin:Count()
    return #self.order
end

local function SortByRemaining(a, b)
    return a.endTime < b.endTime
end

function GroupMixin:Layout()
    table.sort(self.order, SortByRemaining)
    local cfg = self.config
    local up = cfg.growth == "UP"
    local shown = 0
    for i = 1, #self.order do
        local bar = self.order[i]
        bar:ClearAllPoints()
        if i <= cfg.maxBars then
            local offset = (i - 1) * (cfg.height + cfg.spacing)
            if up then
                bar:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", 0, offset)
            else
                bar:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -offset)
            end
            bar:Show()
            shown = shown + 1
        else
            bar:Hide()
        end
    end
    self:SetSize(cfg.width, math.max(cfg.height, shown * (cfg.height + cfg.spacing)))
end

function GroupMixin:OnUpdate()
    local now = GetTime()
    local expired
    for i = 1, #self.order do
        local bar = self.order[i]
        local remaining = bar.endTime - now
        if remaining <= 0 then
            expired = expired or {}
            expired[#expired + 1] = bar
        else
            bar.bar:SetValue(remaining / bar.duration)
            bar.timeText:SetText(FormatTime(remaining))
            if bar.warnBefore and not bar.warned and remaining <= bar.warnBefore then
                bar.warned = true
                bar:SetColor(0.9, 0.2, 0.2)
                ns.EventBus:Fire("BAR_WARNING", bar)
            end
        end
    end
    if expired then
        for i = 1, #expired do
            local bar = expired[i]
            local callback, id = bar.onExpire, bar.id
            if bar.keepOnExpire then
                bar.bar:SetValue(0)
                -- Une barre gardee a zero n'attend pas forcement zero seconde :
                -- une estimation ecoulee attend un evenement, pas la fin d'un
                -- decompte. `expiredText` le dit a la place du chrono.
                bar.timeText:SetText(bar.expiredText or "0.0")
            else
                self:StopBar(id)
            end
            if callback then callback(id) end
        end
    end
    if #self.order == 0 then
        self:StopUpdater()
        if not self.mbsForcedShow and not self.mbsUnlocked then self:Hide() end
    end
end

function GroupMixin:StartUpdater()
    if self.updating then return end
    self.updating = true
    self:SetScript("OnUpdate", self.OnUpdate)
end

function GroupMixin:StopUpdater()
    self.updating = false
    self:SetScript("OnUpdate", nil)
end

--------------------------------------------------------------------------------
-- Fabrique
--------------------------------------------------------------------------------

--- Recupere (ou cree) le groupe attache a `anchorKey`.
-- Le groupe est automatiquement enregistre comme ancre deplacable.
function Bars:GetGroup(anchorKey, opts)
    local group = self.groups[anchorKey]
    if group then return group end

    opts = opts or {}
    local config = {}
    for k, v in pairs(DEFAULTS) do config[k] = v end
    for k, v in pairs(opts) do config[k] = v end

    group = CreateFrame("Frame", nil, UIParent)
    group.config = config
    group.active = {}
    group.order  = {}
    group.pool   = {}

    for name, fn in pairs(GroupMixin) do group[name] = fn end

    group:SetSize(config.width, config.height)
    group:Hide()

    ns.Anchors:Register(group, anchorKey, {
        label        = opts.label or anchorKey,
        defaultPoint = opts.defaultPoint,
        test         = opts.test,
    })

    self.groups[anchorKey] = group
    return group
end

function Bars:StopAll()
    for _, group in pairs(self.groups) do group:StopAll() end
end

--------------------------------------------------------------------------------
-- Barres de test
--------------------------------------------------------------------------------
-- Duree fictive qui boucle tant que le mode test est actif : c'est ce qui permet
-- de placer ses bars hors raid.

function Bars:TestBar(group, id, duration, text, icon, color)
    local key = "TEST_" .. id
    local function start()
        group:StartBar(key, duration, text, icon, {
            color = color,
            onExpire = function()
                if ns.testMode then
                    ns.Scheduler:Schedule("TestBar_" .. key, 0.25, start)
                end
            end,
        })
    end
    start()
end

function Bars:StopTest()
    ns.Scheduler:CancelPrefix("TestBar_")
    for _, group in pairs(self.groups) do
        for i = #group.order, 1, -1 do
            local bar = group.order[i]
            if type(bar.id) == "string" and bar.id:sub(1, 5) == "TEST_" then
                group:StopBar(bar.id)
            end
        end
    end
end
