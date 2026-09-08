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
    "  |cffffff00/mbs list|r — etat des modules",
    "  |cffffff00/mbs enable|disable|toggle <module>|r",
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
