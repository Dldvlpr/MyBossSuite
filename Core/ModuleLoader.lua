-- Core/ModuleLoader.lua
-- Activation / desactivation a chaud.
--
-- Le fichier de module ne fait que DECLARER. Le loader decide. Le pattern
-- `if not db.modules.x.enabled then return end` en tete de fichier n'est evalue
-- qu'une fois au chargement : decocher la case en jeu ne ferait rien jusqu'au
-- prochain /reload.

local _, ns = ...

local EventBus  = ns.EventBus
local Scheduler = ns.Scheduler

ns.modules     = {}
ns.moduleOrder = {}

--------------------------------------------------------------------------------
-- Prototype de module
--------------------------------------------------------------------------------

local ModuleProto = {}
ModuleProto.__index = ModuleProto

--- Enregistre un event Blizzard. `handler` est un nom de methode ou une
-- fonction ; le module retient ses propres handlers pour pouvoir tout couper
-- d'un coup dans OnDisable.
function ModuleProto:RegisterEvent(event, handler)
    handler = handler or event
    if self._events[event] then return end

    local fn
    if type(handler) == "function" then
        fn = function(...) return handler(self, ...) end
    else
        fn = function(...)
            local method = self[handler]
            if method then return method(self, ...) end
        end
    end

    if EventBus:RegisterEvent(event, fn) then
        self._events[event] = fn
    end
end

--- Variante sans wrapper : la fonction est appelee telle quelle par l'EventBus.
-- Reservee au chemin chaud (combat log), ou un niveau d'indirection de plus par
-- event compte reellement.
function ModuleProto:RegisterRawEvent(event, fn)
    if self._events[event] then return end
    if EventBus:RegisterEvent(event, fn) then
        self._events[event] = fn
    end
end

function ModuleProto:UnregisterEvent(event)
    local fn = self._events[event]
    if not fn then return end
    EventBus:UnregisterEvent(event, fn)
    self._events[event] = nil
end

function ModuleProto:UnregisterAllEvents()
    for event, fn in pairs(self._events) do
        EventBus:UnregisterEvent(event, fn)
        self._events[event] = nil
    end
end

function ModuleProto:RegisterMessage(message, handler)
    handler = handler or message
    local fn
    if type(handler) == "function" then
        fn = function(...) return handler(self, ...) end
    else
        fn = function(...)
            local method = self[handler]
            if method then return method(self, ...) end
        end
    end
    EventBus:On(message, fn)
    self._messages[message] = self._messages[message] or {}
    table.insert(self._messages[message], fn)
end

function ModuleProto:UnregisterAllMessages()
    for message, list in pairs(self._messages) do
        for i = 1, #list do EventBus:Off(message, list[i]) end
        self._messages[message] = nil
    end
end

-- Les timers d'un module sont prefixes par son nom : CancelAllTimers ne touche
-- jamais a ceux d'un autre module.
function ModuleProto:TimerKey(key)
    return self.name .. "_" .. key
end

function ModuleProto:Schedule(key, delay, fn, ...)
    return Scheduler:Schedule(self:TimerKey(key), delay, fn, ...)
end

function ModuleProto:Repeat(key, interval, fn)
    return Scheduler:Repeat(self:TimerKey(key), interval, fn)
end

function ModuleProto:CancelTimer(key)
    Scheduler:Cancel(self:TimerKey(key))
end

function ModuleProto:CancelAllTimers()
    Scheduler:CancelPrefix(self.name .. "_")
end

function ModuleProto:GetConfig()
    local modules = ns.db and ns.db.modules
    return modules and modules[self.name]
end

function ModuleProto:IsEnabled()
    return self.isEnabled == true
end

function ModuleProto:Print(...)
    ns.Print(...)
end

function ModuleProto:Debug(...)
    ns.Debug("[" .. self.name .. "]", ...)
end

--------------------------------------------------------------------------------
-- Declaration
--------------------------------------------------------------------------------

--- Declare un module. `defaults` complete PROFILE_DEFAULTS.modules[name].
function ns:NewModule(name, defaults)
    assert(not ns.modules[name], "module deja declare: " .. tostring(name))

    local module = setmetatable({
        name       = name,
        isEnabled  = false,
        _events    = {},
        _messages  = {},
    }, ModuleProto)

    ns.modules[name] = module
    ns.moduleOrder[#ns.moduleOrder + 1] = name

    local profileDefaults = ns.PROFILE_DEFAULTS.modules
    profileDefaults[name] = profileDefaults[name] or { enabled = true }
    if defaults then
        for k, v in pairs(defaults) do
            if profileDefaults[name][k] == nil then profileDefaults[name][k] = v end
        end
    end

    return module
end

function ns:GetModule(name)
    return ns.modules[name]
end

--------------------------------------------------------------------------------
-- Cycle de vie
--------------------------------------------------------------------------------

local function InitializeModule(module)
    if module.initialized then return end
    module.initialized = true
    if module.OnInitialize then
        local ok, err = pcall(module.OnInitialize, module)
        if not ok then ns.Print(("erreur OnInitialize [%s]: %s"):format(module.name, err)) end
    end
end

--- Toute activation / desactivation passe par ici : OnDisable doit etre COMPLET
-- (events, timers, frames). Un module desactive qui laisse une frame visible ou
-- un ticker vivant, c'est le bug qu'on ne trouve jamais.
function ns:SetModuleEnabled(name, enabled)
    local module = ns.modules[name]
    if not module then
        ns.Print("module inconnu: " .. tostring(name))
        return false
    end

    enabled = enabled and true or false

    local config = module:GetConfig()
    if config then config.enabled = enabled end

    if enabled == module.isEnabled then return true end

    InitializeModule(module)
    module.isEnabled = enabled

    local callback = enabled and module.OnEnable or module.OnDisable
    if callback then
        local ok, err = pcall(callback, module)
        if not ok then
            ns.Print(("erreur %s [%s]: %s")
                :format(enabled and "OnEnable" or "OnDisable", name, err))
        end
    end

    if not enabled then
        -- Filet de securite : meme si OnDisable oublie quelque chose.
        module:UnregisterAllEvents()
        module:CancelAllTimers()
    end

    ns.EventBus:Fire("MODULE_STATE_CHANGED", name, enabled)
    return true
end

function ns:IsModuleEnabled(name)
    local module = ns.modules[name]
    return module ~= nil and module.isEnabled
end

function ns:ToggleModule(name)
    local module = ns.modules[name]
    if not module then
        ns.Print("module inconnu: " .. tostring(name))
        return false
    end
    return ns:SetModuleEnabled(name, not module.isEnabled)
end

--- Aligne l'etat runtime de tous les modules sur le profil courant.
-- Appele au login et a chaque changement de profil.
function ns:RefreshModules()
    for i = 1, #ns.moduleOrder do
        local name = ns.moduleOrder[i]
        local module = ns.modules[name]
        InitializeModule(module)
        local config = module:GetConfig()
        local wanted = config and config.enabled or false
        if wanted ~= module.isEnabled then
            ns:SetModuleEnabled(name, wanted)
        end
    end
end

--------------------------------------------------------------------------------
-- Bootstrap
--------------------------------------------------------------------------------

local bootstrap = CreateFrame("Frame")
bootstrap:RegisterEvent("ADDON_LOADED")
bootstrap:RegisterEvent("PLAYER_LOGIN")
bootstrap:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ns.addonName then return end
        self:UnregisterEvent("ADDON_LOADED")
        -- La DB doit exister avant que le moindre module lise ns.db.anchors.
        ns.DB:Initialize()
        for i = 1, #ns.moduleOrder do
            InitializeModule(ns.modules[ns.moduleOrder[i]])
        end
    elseif event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        if not ns.DB.initialized then ns.DB:Initialize() end
        ns:RefreshModules()
        ns.Anchors:ReloadAll()
        if ns.db.locked == false then ns.Anchors:Unlock() end
        ns.EventBus:Fire("MBS_READY")
        ns.Print(("v%s charge (%s) — /mbs pour la configuration.")
            :format(ns.version, ns.flavor))
    end
end)

ns.EventBus:On("PROFILE_CHANGED", function()
    ns:RefreshModules()
end)
