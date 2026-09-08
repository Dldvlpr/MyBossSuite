-- Core/EventBus.lua
-- Une frame unique pour tous les events Blizzard de l'addon, plus un bus de
-- messages internes entre modules.
--
-- Une seule frame COMBAT_LOG_EVENT_UNFILTERED pour tout l'addon, jamais une par
-- module : le combat log est le chemin chaud.
--
-- Deux garde-fous, valables pour les events comme pour les messages :
--   * chaque handler tourne sous pcall : une erreur dans le swing timer ne doit
--     pas priver le boss timer, le kick et le move du meme event ;
--   * les listes ne sont jamais modifiees en place mais remplacees a chaque
--     (des)inscription. Un dispatch en cours garde l'ancienne liste, donc un
--     handler qui se retire (ou retire un autre) pendant un event ne fait
--     jamais appeler nil.

local _, ns = ...

local EventBus = {}
ns.EventBus = EventBus

--------------------------------------------------------------------------------
-- Erreurs de handler
--------------------------------------------------------------------------------
-- Remontees a l'error handler du client (BugSack, dialogue Lua...) plutot
-- qu'avalees, mais pas a chaque event : un handler casse sur le combat log
-- produirait des dizaines d'erreurs par seconde.

local REPORT_INTERVAL = 60
local lastReport = {}   -- [fn] = GetTime() du dernier rapport

local function Report(fn, err)
    local now = GetTime()
    local last = lastReport[fn]
    if last and now - last < REPORT_INTERVAL then return end
    lastReport[fn] = now
    local handler = _G.geterrorhandler and geterrorhandler()
    if handler then
        handler(err)
    else
        ns.Print("erreur dans un handler : " .. tostring(err))
    end
end

local function Call(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then Report(fn, err) end
end

local function Without(list, fn)
    local out = {}
    for i = 1, #list do
        if list[i] ~= fn then out[#out + 1] = list[i] end
    end
    return out
end

local function With(list, fn)
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    out[#out + 1] = fn
    return out
end

--------------------------------------------------------------------------------
-- Events Blizzard
--------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
EventBus.frame = frame

local handlers = {}   -- [event] = { fn, fn, ... }
EventBus.handlers = handlers

frame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do
        Call(list[i], event, ...)
    end
end)

--- Enregistre `fn` sur un event Blizzard. Retourne false si l'event n'existe pas
-- sur ce client (au lieu de lever une erreur).
function EventBus:RegisterEvent(event, fn)
    local list = handlers[event]
    if not list then
        if not ns.EventExists(event) then
            ns.Debug("event inconnu sur ce client:", event)
            return false
        end
        frame:RegisterEvent(event)
        list = {}
    end
    for i = 1, #list do
        if list[i] == fn then return true end
    end
    handlers[event] = With(list, fn)
    return true
end

function EventBus:UnregisterEvent(event, fn)
    local list = handlers[event]
    if not list then return end
    local remaining = Without(list, fn)
    if #remaining == 0 then
        handlers[event] = nil
        frame:UnregisterEvent(event)
    else
        handlers[event] = remaining
    end
end

--------------------------------------------------------------------------------
-- Messages internes
--------------------------------------------------------------------------------

local listeners = {}
EventBus.listeners = listeners

function EventBus:On(message, fn)
    listeners[message] = With(listeners[message] or {}, fn)
    return fn
end

function EventBus:Off(message, fn)
    local list = listeners[message]
    if not list then return end
    local remaining = Without(list, fn)
    listeners[message] = (#remaining > 0) and remaining or nil
end

function EventBus:Fire(message, ...)
    local list = listeners[message]
    if not list then return end
    for i = 1, #list do
        Call(list[i], ...)
    end
end
