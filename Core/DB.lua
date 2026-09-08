-- Core/DB.lua
-- SavedVariables, profils, migrations.
--
-- Les profils sont prevus des la v1 : les rajouter apres coup sur une DB a plat
-- est une migration penible.

local _, ns = ...

local DB = {}
ns.DB = DB

--------------------------------------------------------------------------------
-- Defaults
--------------------------------------------------------------------------------

local DB_VERSION = 1

local DEFAULTS = {
    version     = DB_VERSION,
    profiles    = {},
    profileKeys = {},   -- ["Nom-Royaume"] = "nom du profil"
}

local PROFILE_DEFAULTS = {
    modules = {
        bossTimer         = { enabled = true },
        swingTimer        = { enabled = true },
        cdTracker         = { enabled = false },
        interruptRotation = { enabled = false },
    },
    anchors   = {},   -- [anchorKey] = { point, relTo, relPoint, x, y, scale }
    overrides = {},   -- surcharges par spellId
    locked    = true,
}

ns.PROFILE_DEFAULTS = PROFILE_DEFAULTS

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function CopyDefaults(dst, src)
    if type(dst) ~= "table" then dst = {} end
    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = CopyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

local function DeepCopy(src)
    local out = {}
    for k, v in pairs(src) do
        if type(v) == "table" then out[k] = DeepCopy(v) else out[k] = v end
    end
    return out
end

ns.DeepCopy = DeepCopy

function DB:GetCharacterKey()
    local name  = UnitName("player")
    local realm = GetRealmName and GetRealmName()
    if not name or name == "" then return "Default" end
    return name .. "-" .. (realm or "Unknown")
end

--------------------------------------------------------------------------------
-- Migrations
--------------------------------------------------------------------------------
-- migrations[n] transforme une DB de version n vers la version n+1.
-- Ne jamais supprimer une entree : une DB peut arriver de tres loin.

local migrations = {}
DB.migrations = migrations

-- migrations[1] = function(global) ... end

local function RunMigrations(global)
    local from = tonumber(global.version) or DB_VERSION
    while from < DB_VERSION do
        local step = migrations[from]
        if step then
            local ok, err = pcall(step, global)
            if not ok then
                ns.Print(("migration %d -> %d echouee: %s"):format(from, from + 1, tostring(err)))
                break
            end
        end
        from = from + 1
        global.version = from
    end
    global.version = DB_VERSION
end

--------------------------------------------------------------------------------
-- Profils
--------------------------------------------------------------------------------

function DB:ListProfiles()
    local out = {}
    for name in pairs(ns.global.profiles) do out[#out + 1] = name end
    table.sort(out)
    return out
end

function DB:EnsureProfile(name)
    local profile = ns.global.profiles[name]
    if not profile then
        profile = DeepCopy(PROFILE_DEFAULTS)
        ns.global.profiles[name] = profile
    else
        CopyDefaults(profile, PROFILE_DEFAULTS)
    end
    return profile
end

function DB:GetProfileName()
    return ns.global.profileKeys[self:GetCharacterKey()]
end

--- Bascule le personnage courant sur `name` (cree le profil s'il n'existe pas).
function DB:SetProfile(name)
    if type(name) ~= "string" or name == "" then return false end
    ns.global.profileKeys[self:GetCharacterKey()] = name
    ns.db = self:EnsureProfile(name)
    ns.EventBus:Fire("PROFILE_CHANGED", name)
    return true
end

function DB:CopyProfile(fromName)
    local source = ns.global.profiles[fromName]
    if not source or source == ns.db then return false end
    local current = self:GetProfileName()
    ns.global.profiles[current] = DeepCopy(source)
    ns.db = ns.global.profiles[current]
    ns.EventBus:Fire("PROFILE_CHANGED", current)
    return true
end

function DB:ResetProfile()
    local current = self:GetProfileName()
    ns.global.profiles[current] = DeepCopy(PROFILE_DEFAULTS)
    ns.db = ns.global.profiles[current]
    ns.EventBus:Fire("PROFILE_CHANGED", current)
end

function DB:DeleteProfile(name)
    local current = self:GetProfileName()
    if name == current or not ns.global.profiles[name] then return false end
    ns.global.profiles[name] = nil
    for charKey, profileName in pairs(ns.global.profileKeys) do
        if profileName == name then ns.global.profileKeys[charKey] = nil end
    end
    return true
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------
-- Appele sur ADDON_LOADED du bon addon, AVANT que quoi que ce soit lise
-- ns.db.anchors : sinon nil-error au premier lancement.

function DB:Initialize()
    if self.initialized then return end

    _G.MyBossSuiteDB = CopyDefaults(_G.MyBossSuiteDB, DEFAULTS)
    _G.MyBossSuiteCharDB = _G.MyBossSuiteCharDB or {}

    ns.global = _G.MyBossSuiteDB
    ns.char   = _G.MyBossSuiteCharDB
    ns.debug  = ns.char.debug or false

    RunMigrations(ns.global)

    local charKey = self:GetCharacterKey()
    local profileName = ns.global.profileKeys[charKey]
    if not profileName then
        profileName = charKey
        ns.global.profileKeys[charKey] = profileName
    end

    ns.db = self:EnsureProfile(profileName)

    self.initialized = true
    ns.EventBus:Fire("DB_READY")
end
