-- Core/Scheduler.lua
-- Timers annulables, par cle.
--
-- C_Timer.After n'est pas annulable : un wipe laisse tourner tous les timers du
-- pull precedent, qui explosent au milieu du suivant. Rien dans l'addon ne doit
-- appeler C_Timer directement.

local _, ns = ...

local Timer = ns.Timer

local Scheduler = {}
ns.Scheduler = Scheduler

local active = {}
Scheduler.active = active

--- Programme `fn` dans `delay` secondes sous la cle `key`.
-- Une cle deja utilisee est annulee et remplacee : pas de doublon possible.
function Scheduler:Schedule(key, delay, fn, ...)
    self:Cancel(key)
    local argc = select("#", ...)
    if argc > 0 then
        local a1, a2, a3, a4 = ...
        active[key] = Timer.NewTimer(delay, function()
            active[key] = nil
            fn(a1, a2, a3, a4)
        end)
    else
        active[key] = Timer.NewTimer(delay, function()
            active[key] = nil
            fn()
        end)
    end
    return key
end

--- Repete `fn` toutes les `interval` secondes sous la cle `key`.
function Scheduler:Repeat(key, interval, fn)
    self:Cancel(key)
    active[key] = Timer.NewTicker(interval, fn)
    return key
end

function Scheduler:IsScheduled(key)
    return active[key] ~= nil
end

function Scheduler:Cancel(key)
    local t = active[key]
    if t then
        t:Cancel()
        active[key] = nil
    end
end

--- Annule tous les timers dont la cle commence par `prefix`.
-- `CancelPrefix("BossTimer_")` sur wipe/kill = clear propre d'un module sans
-- toucher aux autres.
function Scheduler:CancelPrefix(prefix)
    local len = #prefix
    for key, t in pairs(active) do
        if key:sub(1, len) == prefix then
            t:Cancel()
            active[key] = nil
        end
    end
end

function Scheduler:CancelAll()
    for key, t in pairs(active) do
        t:Cancel()
        active[key] = nil
    end
end

function Scheduler:CountActive()
    local n = 0
    for _ in pairs(active) do n = n + 1 end
    return n
end
