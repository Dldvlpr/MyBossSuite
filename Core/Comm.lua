-- Core/Comm.lua
-- Messages addon entre joueurs du groupe : un prefixe, un canal choisi tout
-- seul (raid, groupe, ou groupe d'instance), des messages types.
--
-- Ce qui justifie une couche a part plutot que trois appels dans le module
-- boss : le canal depend du client et du type de groupe, ses propres messages
-- reviennent en echo, et la version du protocole doit pouvoir changer sans que
-- deux joueurs a des versions differentes se corrompent mutuellement.
--
-- Format : "<version>\t<type>\t<champ>\t<champ>..." — des champs textuels
-- separes par des tabulations, jamais de serialisation Lua : un message
-- addon est limite a 255 octets et doit rester lisible dans un log.

local _, ns = ...

local Comm = {}
ns.Comm = Comm

local PREFIX  = "MBS"
local VERSION = "1"
local MAX_LEN = 250

Comm.prefix   = PREFIX
Comm.version  = VERSION
Comm.handlers = {}    -- [type] = fn(sender, ...)
Comm.sent     = 0
Comm.received = 0

--------------------------------------------------------------------------------
-- Identite
--------------------------------------------------------------------------------

--- Le nom d'expediteur d'un message addon est "Nom" ou "Nom-Royaume" : on
-- compare le nom court. Un homonyme d'un autre royaume passerait pour soi,
-- c'est un risque assume face a la certitude de l'echo de ses propres messages.
function ns.IsOwnName(name)
    if not name then return false end
    local short = name:match("^([^%-]+)") or name
    return short == UnitName("player")
end

--------------------------------------------------------------------------------
-- Envoi
--------------------------------------------------------------------------------

--- Envoie un message type au groupe. Retourne false hors groupe, ou si le
-- client ne sait pas envoyer : l'appelant n'a rien a faire de plus, la
-- synchronisation est un bonus quand elle est possible.
function Comm:Send(msgType, ...)
    local channel = ns.GetGroupChannel()
    if not channel or not ns.SendAddonMessage then return false end

    local n = select("#", ...)
    local message = VERSION .. "\t" .. msgType
    for i = 1, n do
        message = message .. "\t" .. tostring((select(i, ...)))
    end
    if #message > MAX_LEN then return false end

    local ok = pcall(ns.SendAddonMessage, PREFIX, message, channel)
    if ok then self.sent = self.sent + 1 end
    return ok and true or false
end

--------------------------------------------------------------------------------
-- Reception
--------------------------------------------------------------------------------

function Comm:On(msgType, fn)
    self.handlers[msgType] = fn
end

function Comm:Off(msgType)
    self.handlers[msgType] = nil
end

--- Decoupe sans strsplit : la version du mock n'en gere que deux champs, et
-- une petite table par message recu ne coute rien au rythme ou ils arrivent.
local function Split(message)
    local fields = {}
    for field in (message .. "\t"):gmatch("([^\t]*)\t") do
        fields[#fields + 1] = field
    end
    return fields
end

function Comm:Receive(prefix, message, _, sender)
    if prefix ~= PREFIX or type(message) ~= "string" then return end
    if ns.IsOwnName(sender) then return end

    local fields = Split(message)
    if fields[1] ~= VERSION then return end
    local handler = self.handlers[fields[2]]
    if not handler then return end

    self.received = self.received + 1
    handler(sender, unpack(fields, 3, #fields))
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

if ns.RegisterAddonMessagePrefix then
    pcall(ns.RegisterAddonMessagePrefix, PREFIX)
end

ns.EventBus:RegisterEvent("CHAT_MSG_ADDON", function(_, prefix, message, channel, sender)
    Comm:Receive(prefix, message, channel, sender)
end)
