-- Core/Config.lua
-- Commandes slash + panneau de configuration.

local _, ns = ...

local Config = {}
ns.Config = Config

--------------------------------------------------------------------------------
-- Mode test
--------------------------------------------------------------------------------

function Config:StartTest(anchorKey)
    ns.testMode = true
    local count = ns.Anchors:Test(anchorKey)
    if count > 0 then
        ns.Print(("mode test actif (%d element(s)). /mbs test stop pour arreter."):format(count))
    else
        ns.testMode = false
    end
    return count
end

function Config:StopTest()
    ns.testMode = false
    ns.Bars:StopTest()
    ns.EventBus:Fire("TEST_STOPPED")
    ns.Print("mode test arrete.")
end

function Config:ToggleTest()
    if ns.testMode then self:StopTest() else self:StartTest() end
end

--------------------------------------------------------------------------------
-- Panneau
--------------------------------------------------------------------------------

local panel

local function CreateCheckbox(parent, label, x, y, onClick)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    check:SetScript("OnClick", function(self)
        onClick(self:GetChecked() and true or false)
    end)

    local text = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", check, "RIGHT", 2, 0)
    text:SetText(label)
    check.labelText = text

    return check
end

local function CreateButton(parent, label, width, x, y, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 22)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    button:SetText(label)
    button:SetScript("OnClick", onClick)
    return button
end

function Config:BuildPanel()
    if panel then return panel end

    panel = CreateFrame("Frame", "MyBossSuiteConfigFrame", UIParent)
    panel:SetSize(320, 300)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:SetClampedToScreen(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:Hide()

    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(panel)
    ns.SetSolidColor(bg, 0.05, 0.05, 0.07, 0.92)
    ns.CreateBorder(panel, 1, 0.3, 0.3, 0.35, 1)

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", panel, "TOP", 0, -10)
    title:SetText("MyBossSuite")

    local subtitle = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -2)
    subtitle:SetText(("v%s — client %s"):format(ns.version, ns.flavor))

    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -2, -2)

    local modulesTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    modulesTitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -50)
    modulesTitle:SetText("Modules")

    panel.checks = {}
    local y = -70
    for i = 1, #ns.moduleOrder do
        local name = ns.moduleOrder[i]
        local module = ns.modules[name]
        local check = CreateCheckbox(panel, module.title or name, 16, y, function(checked)
            ns:SetModuleEnabled(name, checked)
        end)
        panel.checks[name] = check
        y = y - 26
    end

    y = y - 14
    local alertsTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    alertsTitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, y)
    alertsTitle:SetText("Alertes")
    y = y - 20

    -- Une ligne par alerte declaree : son, visuel, et un apercu immediat. Le
    -- reste du parametrage (texte, couleur, taille, son choisi) passe par
    -- /mbs alert, qui ne demande pas de widget dedie.
    panel.alertRows = {}
    local alertKeys = ns.Alerts:SortedKeys()
    for i = 1, #alertKeys do
        local key = alertKeys[i]
        local entry = ns.Alerts:Get(key)

        local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, y - 6)
        label:SetWidth(84)
        label:SetJustifyH("LEFT")
        label:SetText(entry.label)

        local soundCheck = CreateCheckbox(panel, "son", 104, y, function(checked)
            ns.Alerts:Set(key, "sound", checked)
        end)
        local visualCheck = CreateCheckbox(panel, "visuel", 166, y, function(checked)
            ns.Alerts:Set(key, "visual", checked)
        end)
        CreateButton(panel, "Test", 60, 244, y - 2, function()
            ns.Alerts:Preview(key)
        end)

        panel.alertRows[key] = { sound = soundCheck, visual = visualCheck }
        y = y - 26
    end

    y = y - 10
    CreateButton(panel, "Unlock / Lock", 130, 16, y, function()
        ns.Anchors:ToggleUnlock()
        Config:Refresh()
    end)
    CreateButton(panel, "Test", 130, 158, y, function()
        Config:ToggleTest()
        Config:Refresh()
    end)

    y = y - 26
    CreateButton(panel, "Reset positions", 272, 16, y, function()
        ns.Anchors:ResetAll()
    end)

    y = y - 30
    local profile = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    profile:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, y)
    profile:SetWidth(280)
    profile:SetJustifyH("LEFT")
    panel.profileText = profile

    panel:SetHeight(math.abs(y) + 46)

    tinsert(UISpecialFrames, "MyBossSuiteConfigFrame")

    return panel
end

function Config:Refresh()
    if not panel or not panel:IsShown() then return end
    for name, check in pairs(panel.checks) do
        check:SetChecked(ns:IsModuleEnabled(name))
    end
    for key, row in pairs(panel.alertRows) do
        local config = ns.Alerts:GetConfig(key)
        row.sound:SetChecked(config.sound ~= false)
        row.visual:SetChecked(config.visual ~= false)
    end
    panel.profileText:SetText(("Profil : |cffffffff%s|r\nAncres : %s   |   Test : %s")
        :format(ns.DB:GetProfileName() or "?",
                ns.Anchors.unlocked and "deverrouillees" or "verrouillees",
                ns.testMode and "actif" or "inactif"))
end

function Config:Toggle()
    self:BuildPanel()
    if panel:IsShown() then
        panel:Hide()
    else
        panel:Show()
        self:Refresh()
    end
end

--------------------------------------------------------------------------------
-- Integration options Blizzard (API divergente selon la version)
--------------------------------------------------------------------------------

function Config:RegisterOptionsPanel()
    local shortcut = CreateFrame("Frame")
    shortcut.name = "MyBossSuite"

    local text = shortcut:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("TOPLEFT", 16, -16)
    text:SetText("MyBossSuite se configure via /mbs.")

    local button = CreateFrame("Button", nil, shortcut, "UIPanelButtonTemplate")
    button:SetSize(160, 22)
    button:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -12)
    button:SetText("Ouvrir la configuration")
    button:SetScript("OnClick", function() Config:Toggle() end)

    if _G.Settings and _G.Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(shortcut, shortcut.name)
        category.ID = shortcut.name
        Settings.RegisterAddOnCategory(category)
    elseif _G.InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(shortcut)
    end
end

--------------------------------------------------------------------------------
-- Slash
--------------------------------------------------------------------------------

local HELP = {
    "|cff33ff99MyBossSuite|r — commandes :",
    "  |cffffff00/mbs|r — ouvre le panneau",
    "  |cffffff00/mbs unlock|r / |cffffff00lock|r — deplacer les elements (molette = taille)",
    "  |cffffff00/mbs reset|r — remet toutes les positions par defaut",
    "  |cffffff00/mbs test|r [anchorKey] — barres factices sur toutes les ancres",
    "  |cffffff00/mbs test stop|r — arrete le mode test",
    "  |cffffff00/mbs test boss <npcId>|r — rejoue la timeline d'un boss hors combat",
    "  |cffffff00/mbs boss|r [status|list [raid|donjon|world]|phase <n>|annonces|compte|phases|cadre|resume|sync on/off]",
    "  |cffffff00/mbs cd|r [status|list|sync|barres|annonce|soi|kick|estimes on/off]",
    "  |cffffff00/mbs anchor|r [<spellId>|remove <spellId>] — ancre dediee pour les barres d'un sort",
    "  |cffffff00/mbs list|r — etat des modules",
    "  |cffffff00/mbs enable|disable|toggle <module>|r",
    "  |cffffff00/mbs alert|r [kick|move] [texte|couleur|taille|duree|son|visuel|flash|test|reset]",
    "  |cffffff00/mbs kick|r [data|spell <id>|auto|focus|portee|dispo|strict on/off]",
    "  |cffffff00/mbs move|r [list|data|add|remove|ignore|unignore|clear|seuil <pct>|apprentissage on/off]",
    "  |cffffff00/mbs profile|r [nom|list|copy <nom>|reset]",
    "  |cffffff00/mbs debug|r — bascule les messages de debug",
}

local function PrintHelp()
    for i = 1, #HELP do print(HELP[i]) end
end

local function ListModules()
    ns.Print("modules :")
    for i = 1, #ns.moduleOrder do
        local name = ns.moduleOrder[i]
        local module = ns.modules[name]
        print(("  %s |cffffff00%s|r — %s"):format(
            module.isEnabled and "|cff00ff00[on]|r " or "|cffff0000[off]|r",
            name, module.title or ""))
    end
end

local function HandleProfile(arg1, arg2)
    if not arg1 or arg1 == "" then
        ns.Print("profil courant : " .. (ns.DB:GetProfileName() or "?"))
        return
    end
    if arg1 == "list" then
        ns.Print("profils : " .. table.concat(ns.DB:ListProfiles(), ", "))
    elseif arg1 == "copy" then
        if arg2 and ns.DB:CopyProfile(arg2) then
            ns.Print("profil copie depuis " .. arg2)
        else
            ns.Print("copie impossible : profil introuvable.")
        end
    elseif arg1 == "reset" then
        ns.DB:ResetProfile()
        ns.Print("profil reinitialise.")
    else
        ns.DB:SetProfile(arg1)
        ns.Print("profil actif : " .. arg1)
    end
end

local function HandleTest(arg1, arg2)
    if arg1 == "stop" then
        Config:StopTest()
    elseif arg1 == "boss" then
        local module = ns:GetModule("bossTimer")
        if not module or not module.isEnabled then
            ns.Print("le module bossTimer doit etre actif pour /mbs test boss.")
            return
        end
        module:TestBoss(tonumber(arg2))
    elseif arg1 and arg1 ~= "" then
        Config:StartTest(arg1)
    else
        Config:ToggleTest()
    end
    Config:Refresh()
end

--------------------------------------------------------------------------------
-- Ancres dediees par sort (/mbs anchor)
--------------------------------------------------------------------------------
-- Par defaut toutes les barres de boss s'empilent sur l'ancre generique. Un sort
-- qu'on veut voir ailleurs (gros CD a placer pres du perso) recoit sa propre
-- ancre, deplacable avec /mbs unlock comme le reste.

local function HandleAnchor(arg1, arg2)
    local module = ns:GetModule("bossTimer")
    if not module then return end

    local option = arg1 and arg1:lower()
    if not option or option == "" or option == "list" then
        local ids = module:ListOverrideAnchors()
        ns.Print(("ancres dediees : %d"):format(#ids))
        for i = 1, #ids do
            print(("    %d — %s  |cffaaaaaaBossTimer_Alert_%d|r"):format(
                ids[i], ns.GetSpellName(ids[i]) or "?", ids[i]))
        end
        print("  |cffaaaaaa/mbs anchor <spellId> pour en creer une, /mbs anchor remove <spellId> pour la retirer|r")
        return
    end

    if option == "remove" or option == "del" or option == "supprimer" then
        local spellId = tonumber((arg2 or ""):match("^%S+"))
        if not spellId then return ns.Print("usage : /mbs anchor remove <spellId>") end
        if module:RemoveOverrideAnchor(spellId) then
            ns.Print(("ancre dediee retiree : %d — ses barres reviennent sur l'ancre generique."):format(spellId))
        else
            ns.Print(("aucune ancre dediee pour %d."):format(spellId))
        end
        return
    end

    local spellId = tonumber(option)
    if not spellId then
        return ns.Print("usage : /mbs anchor [list | <spellId> | remove <spellId>]")
    end
    local anchorKey = module:AddOverrideAnchor(spellId)
    if anchorKey then
        ns.Print(("ancre dediee creee pour %d (%s) : /mbs unlock pour la placer, /mbs test %s pour la voir.")
            :format(spellId, ns.GetSpellName(spellId) or "?", anchorKey))
    end
end

--------------------------------------------------------------------------------
-- Alertes parametrables (/mbs alert)
--------------------------------------------------------------------------------

local function Words(text)
    local out = {}
    for word in (text or ""):gmatch("%S+") do out[#out + 1] = word end
    return out
end

local TRUE_WORDS  = { on = true, ["1"] = true, oui = true, yes = true, ["true"] = true }
local FALSE_WORDS = { off = true, ["0"] = true, non = true, no = true, ["false"] = true }

--- Retourne nil quand le mot n'est pas un booleen : l'appelant peut alors le
-- traiter comme une valeur (un nom de son, par exemple).
local function ParseBool(word)
    if not word then return nil end
    word = word:lower()
    if TRUE_WORDS[word] then return true end
    if FALSE_WORDS[word] then return false end
    return nil
end

-- Noms francais et anglais acceptes indifferemment : personne ne devrait avoir
-- a deviner dans quelle langue l'addon a ete ecrit.
local ALERT_FIELDS = {
    texte = "text",     text     = "text",
    couleur = "color",  color    = "color",
    taille = "fontSize", size    = "fontSize",
    duree = "duration", duration = "duration",
    son = "sound",      sound    = "sound",
    visuel = "visual",  visual   = "visual",
    flash = "flash",
    canal = "channel",  channel  = "channel",
}

local function AlertValue(config, field)
    local value = config[field]
    if value == nil then return ns.ALERT_DEFAULTS[field] end
    return value
end

local function PrintAlert(key)
    local entry  = ns.Alerts:Get(key)
    local config = ns.Alerts:GetConfig(key)
    local color  = AlertValue(config, "color")
    print(("  |cffffff00%s|r — %s"):format(key, entry.label))
    print(("     texte |cffffffff%s|r   taille %s   duree %ss   couleur %.2f %.2f %.2f")
        :format(tostring(AlertValue(config, "text")),
                tostring(AlertValue(config, "fontSize")),
                tostring(AlertValue(config, "duration")),
                color[1], color[2], color[3]))
    print(("     visuel %s   flash %s   son %s |cffaaaaaa(%s)|r"):format(
        AlertValue(config, "visual") ~= false and "on" or "off",
        AlertValue(config, "flash") ~= false and "on" or "off",
        AlertValue(config, "sound") ~= false and "on" or "off",
        tostring(AlertValue(config, "soundName"))))
end

local function ListAlerts()
    ns.Print("alertes :")
    local keys = ns.Alerts:SortedKeys()
    for i = 1, #keys do PrintAlert(keys[i]) end
    print("  |cffaaaaaa/mbs alert <cle> son <preset|id|chemin>|r — presets : "
        .. "raidwarning, readycheck, alarm, ping, murloc")
end

local function HandleAlert(arg1, arg2)
    if not arg1 or arg1 == "" then return ListAlerts() end

    local key = arg1:lower()
    if not ns.Alerts:Get(key) then
        ns.Print(("alerte inconnue : %s (essaie /mbs alert)"):format(arg1))
        return
    end

    local words = Words(arg2)
    local property = words[1] and words[1]:lower()

    if not property then return PrintAlert(key) end

    if property == "test" or property == "apercu" then
        ns.Alerts:Preview(key)
        return
    end

    if property == "reset" then
        if ns.Alerts:Reset(key) then
            ns.Print(("alerte %s remise par defaut."):format(key))
            PrintAlert(key)
        end
        return
    end

    local field = ALERT_FIELDS[property]
    if not field then
        ns.Print(("propriete inconnue : %s"):format(property))
        return
    end

    if field == "sound" then
        -- `son off` coupe le son ; `son alarm` choisit lequel jouer et le
        -- rallume, parce que choisir un son puis devoir le rallumer serait idiot.
        local bool = ParseBool(words[2])
        if bool ~= nil then
            ns.Alerts:Set(key, "sound", bool)
        elseif words[2] then
            local value = arg2:match("^%S+%s+(.*)$")
            ns.Alerts:Set(key, "soundName", tonumber(value) or value)
            ns.Alerts:Set(key, "sound", true)
            ns.Alerts:PlaySound(key, true)
        end
    elseif field == "visual" or field == "flash" then
        local bool = ParseBool(words[2])
        if bool == nil then
            ns.Print(("usage : /mbs alert %s %s on|off"):format(key, property))
            return
        end
        ns.Alerts:Set(key, field, bool)
    elseif field == "color" then
        local r, g, b = tonumber(words[2]), tonumber(words[3]), tonumber(words[4])
        if not r or not g or not b then
            ns.Print(("usage : /mbs alert %s couleur <r> <g> <b>  (0 a 1)"):format(key))
            return
        end
        ns.Alerts:Set(key, "color", { r, g, b })
    elseif field == "fontSize" or field == "duration" then
        local value = tonumber(words[2])
        if not value or value <= 0 then
            ns.Print(("usage : /mbs alert %s %s <nombre>"):format(key, property))
            return
        end
        ns.Alerts:Set(key, field, value)
    else
        local value = arg2:match("^%S+%s+(.*)$")
        if not value or value == "" then
            ns.Print(("usage : /mbs alert %s %s <valeur>"):format(key, property))
            return
        end
        ns.Alerts:Set(key, field, value)
    end

    PrintAlert(key)
end

--------------------------------------------------------------------------------
-- Module kick (/mbs kick)
--------------------------------------------------------------------------------

local function PrintStatus(module)
    if not module then return end
    ns.Print(("%s : %s"):format(module.title or module.name,
        module.isEnabled and "|cff00ff00actif|r" or "|cffff0000inactif|r"))
    local lines = module.StatusLines and module:StatusLines()
    for i = 1, #(lines or {}) do print("  " .. lines[i]) end
end

local function PrintSpellList(module, ids, title)
    if #ids == 0 then
        print(("  %s : |cffaaaaaa(vide)|r"):format(title))
        return
    end
    print(("  %s :"):format(title))
    for i = 1, #ids do
        print(("    %d — %s"):format(ids[i], ns.GetSpellName(ids[i]) or "?"))
    end
end

local KICK_FLAGS = {
    focus  = "watchFocus",
    portee = "checkRange", range = "checkRange",
    dispo  = "onlyWhenReady", ready = "onlyWhenReady",
    -- `strict` : sur le repli combat log, ne rien annoncer qui ne soit prouve
    -- interruptible par la data. Zero faux positif, au prix des sorts non
    -- couverts. Sans effet quand l'API du client repond (elle prime toujours).
    strict = "dataOnly", dataonly = "dataOnly",
}

local function HandleKick(arg1, arg2)
    local module = ns:GetModule("interruptAlert")
    if not module then return end

    local option = arg1 and arg1:lower()
    if not option or option == "" or option == "status" then
        return PrintStatus(module)
    end

    local config = module:GetConfig()
    if not config then return end

    if option == "data" then
        local ids = module:ListData()
        ns.Print(("sorts interruptibles connus (data livree) : %d"):format(#ids))
        PrintSpellList(module, ids, "prouves par les logs")
        return
    end

    if option == "spell" then
        local value = (arg2 or ""):match("^%S+")
        if value == "auto" or value == "" or value == nil then
            config.spellId = nil
        else
            local spellId = tonumber(value)
            if not spellId then
                ns.Print("usage : /mbs kick spell <spellId> | auto")
                return
            end
            config.spellId = spellId
        end
        module:ResolveInterrupt()
        return PrintStatus(module)
    end

    local field = KICK_FLAGS[option]
    if not field then
        ns.Print("usage : /mbs kick [status | data | spell <id>|auto | "
            .. "focus|portee|dispo|strict on|off]")
        return
    end

    local bool = ParseBool((arg2 or ""):match("^%S+"))
    if bool == nil then bool = not (config[field] ~= false) end
    config[field] = bool
    module:UpdateWatchedGUIDs()
    PrintStatus(module)
end

--------------------------------------------------------------------------------
-- Module move (/mbs move)
--------------------------------------------------------------------------------

local function HandleMove(arg1, arg2)
    local module = ns:GetModule("moveAlert")
    if not module then return end

    local option = arg1 and arg1:lower()
    if not option or option == "" or option == "status" then
        return PrintStatus(module)
    end

    local config = module:GetConfig()
    if not config then return end

    local value = (arg2 or ""):match("^%S+")
    local spellId = tonumber(value)

    if option == "list" then
        ns.Print(("alerte move : %d zone(s) livree(s) — /mbs move data pour les voir")
            :format(module:CountData()))
        PrintSpellList(module, module:ListSpells(), "zones apprises")
        PrintSpellList(module, module:ListIgnored(), "sorts ignores")
    elseif option == "data" then
        local ids = module:ListData()
        ns.Print(("zones livrees avec l'addon : %d"):format(#ids))
        PrintSpellList(module, ids, "mesurees sur les logs")
    elseif option == "add" then
        if not spellId then return ns.Print("usage : /mbs move add <spellId>") end
        config.spells[spellId] = true
        config.ignored[spellId] = nil
        ns.Print(("zone ajoutee : %d (%s)"):format(spellId, ns.GetSpellName(spellId) or "?"))
    elseif option == "remove" then
        if not spellId then return ns.Print("usage : /mbs move remove <spellId>") end
        ns.Print(module:Forget(spellId) and ("zone retiree : " .. spellId)
            or ("ce sort n'est pas dans la liste : " .. spellId))
    elseif option == "ignore" then
        if not spellId then return ns.Print("usage : /mbs move ignore <spellId>") end
        module:Ignore(spellId)
        ns.Print(("sort ignore : %d (%s)"):format(spellId, ns.GetSpellName(spellId) or "?"))
    elseif option == "unignore" then
        if not spellId then return ns.Print("usage : /mbs move unignore <spellId>") end
        ns.Print(module:Unignore(spellId) and ("sort reactive : " .. spellId)
            or ("ce sort n'etait pas ignore : " .. spellId))
    elseif option == "clear" then
        wipe(config.spells)
        ns.Print("liste des zones videe.")
    elseif option == "seuil" or option == "threshold" then
        local pct = tonumber(value)
        if not pct or pct < 0 or pct > 100 then
            return ns.Print("usage : /mbs move seuil <pourcentage des PV max>")
        end
        config.threshold = pct / 100
        PrintStatus(module)
    elseif option == "apprentissage" or option == "learn" then
        local bool = ParseBool(value)
        if bool == nil then bool = not (config.learn ~= false) end
        config.learn = bool
        PrintStatus(module)
    else
        ns.Print("usage : /mbs move [status|list|data|add|remove|ignore|unignore|clear|"
            .. "seuil <pct>|apprentissage on|off]")
    end
end

--------------------------------------------------------------------------------
-- Module boss timer (/mbs boss)
--------------------------------------------------------------------------------

local KIND_WORDS = {
    raid = "raid",
    donjon = "dungeon", dungeon = "dungeon",
    world = "world", monde = "world", ["world-boss"] = "world", worldboss = "world",
}

local KIND_LABELS = { raid = "raid", dungeon = "donjon", world = "world boss" }

local BOSS_FLAGS = {
    annonces = "announce", annonce = "announce", announce = "announce",
    compte = "countdown", countdown = "countdown",
    phases = "phaseAlert", phase_alerte = "phaseAlert", phasealert = "phaseAlert",
    cadre = "phaseFrame", frame = "phaseFrame",
    resume = "summary", summary = "summary",
    son = "sound", sound = "sound",
    sync = "sync", synchro = "sync",
}

local function HandleBoss(arg1, arg2)
    local module = ns:GetModule("bossTimer")
    if not module then return end

    local option = arg1 and arg1:lower()
    if not option or option == "" or option == "status" then
        return PrintStatus(module)
    end

    local config = module:GetConfig()
    if not config then return end
    local value = (arg2 or ""):match("^%S+")

    if option == "list" or option == "liste" then
        local kind = value and KIND_WORDS[value:lower()] or nil
        local entries = module:ListData(kind)
        ns.Print(("rencontres connues (%s) : %d"):format(ns.flavor, #entries))
        local lastKind
        for i = 1, #entries do
            local entry = entries[i]
            if entry.kind ~= lastKind then
                lastKind = entry.kind
                print(("  |cffffff00%s|r"):format(KIND_LABELS[entry.kind] or entry.kind))
            end
            local def = entry.def
            print(("    %d — %s%s  |cffaaaaaa(%d timer(s), %d phase(s))|r%s"):format(
                entry.npcId, def.name or "?",
                def.zone and (" — " .. def.zone) or "",
                #(def.timers or {}), #(def.phases or {}),
                def.provisional and " |cffff7f00provisoire|r" or ""))
        end
        if #entries == 0 then
            print("    |cffaaaaaa(aucune — voir tools/wcl-ingest)|r")
        end
        return
    end

    if option == "phase" then
        local index = tonumber(value)
        if not index then return ns.Print("usage : /mbs boss phase <n>") end
        if not module.def then
            return ns.Print("aucune rencontre en cours (ni en test).")
        end
        if module.phase == index then
            ns.Print(("deja en phase %d."):format(index))
        elseif module:SetPhase(index, "manual") then
            ns.Print(("phase forcee : %s"):format(module:PhaseLabel()))
        else
            ns.Print(("phase %d inconnue pour cette rencontre."):format(index))
        end
        return
    end

    local field = BOSS_FLAGS[option]
    if not field then
        ns.Print("usage : /mbs boss [status | list [raid|donjon|world] | phase <n> | "
            .. "annonces|compte|phases|cadre|resume|son|sync on|off]")
        return
    end

    local bool = ParseBool(value)
    if bool == nil then bool = not (config[field] ~= false) end
    config[field] = bool
    if field == "phaseFrame" and not bool then module:HidePhaseFrame() end
    PrintStatus(module)
end

--------------------------------------------------------------------------------
-- Module CD Tracker (/mbs cd)
--------------------------------------------------------------------------------

local CD_FLAGS = {
    barres = "bars", bars = "bars",
    annonce = "broadcast", broadcast = "broadcast", diffusion = "broadcast",
    soi = "showSelf", self = "showSelf",
    kick = "interrupts", interrupts = "interrupts",
    estimes = "estimates", estimates = "estimates", estimations = "estimates",
}

local SOURCE_LABELS = {
    self = "soi", mbs = "MyBossSuite", lor = "LibOpenRaid", static = "estime",
}

local function PrintCDStatus(module)
    local status = module:Status()
    ns.Print(("CD Tracker : %d joueur(s) suivi(s), %d sort(s) annonce(s) par toi.")
        :format(status.units, status.mySpells))
    print(("  LibOpenRaid : |cffffff00%s|r"):format(status.libWhy))
    local parts = {}
    for source, count in pairs(status.counts) do
        if count > 0 then
            parts[#parts + 1] = ("%s %d"):format(SOURCE_LABELS[source] or source, count)
        end
    end
    print("  sources : " .. (#parts > 0 and table.concat(parts, ", ") or "aucune donnee"))

    local config = module:GetConfig()
    if config then
        print(("  barres %s | annonce %s | soi %s | estimes %s"):format(
            config.bars ~= false and "on" or "off",
            config.broadcast ~= false and "on" or "off",
            config.showSelf ~= false and "on" or "off",
            config.estimates ~= false and "on" or "off"))
    end
end

local function HandleCD(arg1, arg2)
    local module = ns:GetModule("cdTracker")
    if not module then return end

    local option = arg1 and arg1:lower()
    if not option or option == "" or option == "status" then
        return PrintCDStatus(module)
    end

    if option == "list" or option == "liste" then
        local entries = module:List()
        ns.Print(("cooldowns connus : %d"):format(#entries))
        for i = 1, #entries do
            local entry = entries[i]
            local name = ns.GetSpellName(entry.spellId) or ("sort " .. entry.spellId)
            print(("  %-16s %-22s %5.1fs  |cffaaaaaa%s|r"):format(
                entry.unit, name, entry.remaining,
                SOURCE_LABELS[entry.source] or entry.source))
        end
        if #entries == 0 then
            print("    |cffaaaaaa(personne n'a encore annonce de cooldown)|r")
        end
        return
    end

    if option == "sync" or option == "demande" then
        ns.Comm:Send("CDREQ")
        module:BroadcastAll()
        return ns.Print("etat demande au groupe, et le tien annonce.")
    end

    local field = CD_FLAGS[option]
    if not field then
        return ns.Print("usage : /mbs cd [status|list|sync|barres on/off|annonce on/off|"
            .. "soi on/off|kick on/off|estimes on/off]")
    end

    local config = module:GetConfig()
    if not config then return end
    local value = (arg2 or ""):match("^%S+")
    local bool = ParseBool(value)
    if bool == nil then
        return ns.Print(("usage : /mbs cd %s on|off"):format(option))
    end

    config[field] = bool
    if field == "interrupts" then module:ForgetMySpells() end
    if field == "bars" or field == "showSelf" or field == "estimates" then
        module:RefreshBars()
    end
    PrintCDStatus(module)
end

SLASH_MYBOSSSUITE1 = "/mbs"
SLASH_MYBOSSSUITE2 = "/mybosssuite"

SlashCmdList["MYBOSSSUITE"] = function(input)
    input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = input:match("^(%S*)%s*(.*)$")
    cmd = (cmd or ""):lower()
    local arg1, arg2 = rest:match("^(%S*)%s*(.*)$")

    if cmd == "" then
        Config:Toggle()
    elseif cmd == "help" then
        PrintHelp()
    elseif cmd == "unlock" then
        ns.Anchors:Unlock(); Config:Refresh()
    elseif cmd == "lock" then
        ns.Anchors:Lock(); Config:Refresh()
    elseif cmd == "reset" then
        ns.Anchors:ResetAll()
    elseif cmd == "test" then
        HandleTest(arg1, arg2)
    elseif cmd == "list" then
        ListModules()
    elseif cmd == "enable" or cmd == "disable" then
        ns:SetModuleEnabled(arg1, cmd == "enable")
        ns.Print(("%s : %s"):format(arg1, cmd == "enable" and "actif" or "inactif"))
        Config:Refresh()
    elseif cmd == "toggle" then
        ns:ToggleModule(arg1)
        ns.Print(("%s : %s"):format(arg1, ns:IsModuleEnabled(arg1) and "actif" or "inactif"))
        Config:Refresh()
    elseif cmd == "anchor" or cmd == "ancre" then
        HandleAnchor(arg1 ~= "" and arg1 or nil, arg2)
    elseif cmd == "alert" or cmd == "alerte" then
        HandleAlert(arg1 ~= "" and arg1 or nil, arg2)
    elseif cmd == "kick" then
        HandleKick(arg1 ~= "" and arg1 or nil, arg2)
    elseif cmd == "move" then
        HandleMove(arg1 ~= "" and arg1 or nil, arg2)
    elseif cmd == "boss" then
        HandleBoss(arg1 ~= "" and arg1 or nil, arg2)
    elseif cmd == "cd" then
        HandleCD(arg1 ~= "" and arg1 or nil, arg2)
    elseif cmd == "profile" then
        HandleProfile(arg1 ~= "" and arg1 or nil, arg2 ~= "" and arg2 or nil)
    elseif cmd == "debug" then
        ns.debug = not ns.debug
        ns.char.debug = ns.debug
        ns.Print("debug " .. (ns.debug and "actif" or "inactif"))
    else
        PrintHelp()
    end
end

ns.EventBus:On("MBS_READY", function()
    Config:RegisterOptionsPanel()
end)

ns.EventBus:On("MODULE_STATE_CHANGED", function()
    Config:Refresh()
end)
