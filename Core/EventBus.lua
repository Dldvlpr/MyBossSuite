-- Core/EventBus.lua
-- Une frame unique pour tous les events Blizzard de l'addon, plus un bus de
-- messages internes entre modules.
--
-- Une seule frame COMBAT_LOG_EVENT_UNFILTERED pour tout l'addon, jamais une par
-- module : le combat log est le chemin chaud.

local _, ns = ...

local EventBus = {}
ns.EventBus = EventBus

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
        list[i](event, ...)
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
        list = {}
        handlers[event] = list
        frame:RegisterEvent(event)
    end
    for i = 1, #list do
        if list[i] == fn then return true end
    end
    list[#list + 1] = fn
    return true
end

function EventBus:UnregisterEvent(event, fn)
    local list = handlers[event]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == fn then tremove(list, i) end
    end
    if #list == 0 then
        handlers[event] = nil
        frame:UnregisterEvent(event)
    end
end

--------------------------------------------------------------------------------
-- Messages internes
--------------------------------------------------------------------------------

local listeners = {}
EventBus.listeners = listeners

function EventBus:On(message, fn)
    local list = listeners[message]
    if not list then
        list = {}
        listeners[message] = list
    end
    list[#list + 1] = fn
    return fn
end

function EventBus:Off(message, fn)
    local list = listeners[message]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == fn then tremove(list, i) end
    end
end

function EventBus:Fire(message, ...)
    local list = listeners[message]
    if not list then return end
    for i = 1, #list do
        list[i](...)
    end
end
