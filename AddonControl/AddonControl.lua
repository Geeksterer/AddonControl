local ADDON_NAME = "AddonControl"
local AddonControl = CreateFrame("Frame", "AddonControlCoreFrame")

-- Pull title, version, and author dynamically from the .toc file only
local ADDON_TITLE = GetAddOnMetadata(ADDON_NAME, "Title") or ADDON_NAME
local ADDON_VERSION = GetAddOnMetadata(ADDON_NAME, "Version") or ""
local ADDON_AUTHOR = GetAddOnMetadata(ADDON_NAME, "Author") or ""
local FOOTER_TEXT = string.format("%s v%s by %s", ADDON_TITLE, ADDON_VERSION, ADDON_AUTHOR)

-- ============================================================================
-- STATE & CONSTANTS
-- ============================================================================
local NUM_ROWS = 14
local ROW_HEIGHT = 25
local addonList = {}
local enabledState = {} -- Tracks checkbox state for next reload: [addonName] = true/false
local sortColumn = "name" -- Default sort by alphabetical addon name ("name" or "memory")
local sortAscending = true -- Default A-Z
local pendingReload = false
local selectedProfileForOptions = nil
local reportFormat = "DEFAULT" -- "DEFAULT", "DISCORD", or "TAB"
local activeSlashCommand = "/ac"
local loginGreetingPending = true

-- Helper to print formatted chat messages to General Chat
local function PrintMsg(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[" .. ADDON_TITLE .. "]:|r " .. tostring(msg))
    end
end

-- Combined memory string for UI display
local function FormatMemory(kb)
    if not kb or kb <= 0 then
        return "0 KB"
    elseif kb >= 1024 then
        return string.format("%.2f MB", kb / 1024)
    else
        return string.format("%.0f KB", kb)
    end
end

-- Split memory value and unit into two separate strings for Excel/Report sorting
local function FormatMemorySplit(kb)
    if not kb or kb <= 0 then
        return "0", "KB"
    elseif kb >= 1024 then
        return string.format("%.2f", kb / 1024), "MB"
    else
        return string.format("%.0f", kb), "KB"
    end
end

-- Strip WoW color codes for clean 3.3.5 output & alphabetical sorting
local function StripColors(str)
    if not str then return "" end
    return str:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
end

-- ============================================================================
-- PANEL NAVIGATION SYSTEM (Supports "Back to Parent Panel" on every panel)
-- ============================================================================
local MainFrame, ReportFrame, ProfileOptionsFrame

local function NavigateToPanel(targetPanel, sourcePanel)
    if not targetPanel then return end
    targetPanel.parentPanel = sourcePanel

    if targetPanel.backBtn then
        if sourcePanel and sourcePanel.panelTitle then
            targetPanel.backBtn:SetText("<< Back (" .. sourcePanel.panelTitle .. ")")
            targetPanel.backBtn:Enable()
        else
            targetPanel.backBtn:SetText("<< Back")
            targetPanel.backBtn:Disable()
        end
    end

    targetPanel:Show()
    targetPanel:Raise()
end

local function GoBackFromPanel(currentPanel)
    if not currentPanel then return end
    local parent = currentPanel.parentPanel
    currentPanel:Hide()

    if parent then
        parent:Show()
        parent:Raise()
    end
end

-- ============================================================================
-- DATABASE & CORE LOGIC
-- ============================================================================
local function GetCurrentCheckedAddonsTable()
    local tbl = {}
    for i = 1, GetNumAddOns() do
        local name = GetAddOnInfo(i)
        if name and enabledState[name] then
            tbl[name] = true
        end
    end
    return tbl
end

local function InitializeDatabase()
    if type(AddonControlDB) ~= "table" then
        AddonControlDB = {}
    end
    if type(AddonControlDB.profiles) ~= "table" then
        AddonControlDB.profiles = {}
    end
    if type(AddonControlDB.alwaysLoad) ~= "table" then
        AddonControlDB.alwaysLoad = {}
    end
    if type(AddonControlDB.minimapPos) ~= "number" then
        AddonControlDB.minimapPos = 225
    end

    -- Self-protection: Always keep AddonControl locked so user cannot lock themselves out
    AddonControlDB.alwaysLoad[ADDON_NAME] = true

    if type(AddonControlCharDB) ~= "table" then
        AddonControlCharDB = {}
    end

    -- Populate initial enabledState from client
    for i = 1, GetNumAddOns() do
        local name, _, _, enabled = GetAddOnInfo(i)
        if name then
            enabledState[name] = (enabled == 1 or enabled == true or IsAddOnLoaded(i) == 1)
        end
    end

    -- Ensure at least a "Default" profile exists in account-wide storage
    if not AddonControlDB.defaultProfile or not AddonControlDB.profiles[AddonControlDB.defaultProfile] then
        local firstProfile = next(AddonControlDB.profiles)
        if firstProfile then
            AddonControlDB.defaultProfile = firstProfile
        else
            AddonControlDB.defaultProfile = "Default"
            AddonControlDB.profiles["Default"] = GetCurrentCheckedAddonsTable()
        end
    end
end

-- Checks if current enabledState differs from the active saved profile (ignoring Always Load)
local function IsActiveProfileModified()
    local activeName = AddonControlCharDB.activeProfile
    if not activeName or not AddonControlDB.profiles[activeName] then
        return true
    end
    local savedProfile = AddonControlDB.profiles[activeName]
    for i = 1, GetNumAddOns() do
        local name = GetAddOnInfo(i)
        if name and not AddonControlDB.alwaysLoad[name] then
            local isChecked = enabledState[name] and true or false
            local inProfile = savedProfile[name] and true or false
            if isChecked ~= inProfile then
                return true
            end
        end
    end
    return false
end

-- Enable an addon and recursively enable its required parent dependencies
local function SetAddonEnabledWithDeps(addonNameOrIndex, shouldEnable, alsoLockDeps)
    local name = GetAddOnInfo(addonNameOrIndex)
    if not name then return end

    if not shouldEnable and AddonControlDB.alwaysLoad[name] then
        return -- Cannot disable a locked addon
    end

    enabledState[name] = shouldEnable and true or false
    if shouldEnable then
        EnableAddOn(name)
        local deps = { GetAddOnDependencies(addonNameOrIndex) }
        for _, depName in ipairs(deps) do
            if depName and depName ~= "" then
                enabledState[depName] = true
                EnableAddOn(depName)
                if alsoLockDeps then
                    AddonControlDB.alwaysLoad[depName] = true
                end
            end
        end
    else
        DisableAddOn(name)
    end
    pendingReload = true
end

-- Apply a saved profile to the client
local function ApplyProfile(profileName)
    local profileData = AddonControlDB.profiles[profileName]
    if not profileData then return end

    AddonControlCharDB.activeProfile = profileName
    for i = 1, GetNumAddOns() do
        local name = GetAddOnInfo(i)
        if name then
            if AddonControlDB.alwaysLoad[name] or profileData[name] then
                enabledState[name] = true
                EnableAddOn(name)
            else
                enabledState[name] = false
                DisableAddOn(name)
            end
        end
    end
    pendingReload = true
    if MainFrame and MainFrame:IsShown() then
        AddonControl:RefreshMainWindow(false)
    end
end

-- ============================================================================
-- STATIC POPUP DIALOGS (Confirmation Boxes for ALL Profile Actions)
-- ============================================================================
StaticPopupDialogs["ADDONCONTROL_CONFIRM_LOAD"] = {
    text = "Load profile '%s'?\n\nThis will update your selected addons (keeping locked Always-Load addons active).",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, profileName)
        ApplyProfile(profileName)
        if ProfileOptionsFrame and ProfileOptionsFrame:IsShown() then
            GoBackFromPanel(ProfileOptionsFrame)
        end
        PrintMsg("Loaded profile '" .. profileName .. "'. Click Reload UI to apply.")
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

StaticPopupDialogs["ADDONCONTROL_CONFIRM_SAVE"] = {
    text = "Save your currently checked addons to profile '%s'?\n\nThis will overwrite the existing settings for '%s'.",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, profileName)
        AddonControlDB.profiles[profileName] = GetCurrentCheckedAddonsTable()
        AddonControlCharDB.activeProfile = profileName
        if ProfileOptionsFrame and ProfileOptionsFrame:IsShown() then
            GoBackFromPanel(ProfileOptionsFrame)
        end
        if MainFrame and MainFrame:IsShown() then
            AddonControl:RefreshMainWindow(false)
        end
        PrintMsg("Saved current addon selection to profile '" .. profileName .. "'.")
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

StaticPopupDialogs["ADDONCONTROL_CONFIRM_DELETE"] = {
    text = "Are you sure you want to permanently delete profile '%s'?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, profileName)
        AddonControlDB.profiles[profileName] = nil
        local nextAvailable = next(AddonControlDB.profiles)
        if not nextAvailable then
            AddonControlDB.profiles["Default"] = GetCurrentCheckedAddonsTable()
            nextAvailable = "Default"
        end
        if AddonControlDB.defaultProfile == profileName then
            AddonControlDB.defaultProfile = nextAvailable
        end
        if AddonControlCharDB.activeProfile == profileName then
            AddonControlCharDB.activeProfile = "Custom"
        end
        selectedProfileForOptions = nextAvailable
        if ProfileOptionsFrame and ProfileOptionsFrame:IsShown() then
            GoBackFromPanel(ProfileOptionsFrame)
        end
        if MainFrame and MainFrame:IsShown() then
            AddonControl:RefreshMainWindow(false)
        end
        PrintMsg("Deleted profile '" .. profileName .. "'.")
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

StaticPopupDialogs["ADDONCONTROL_CONFIRM_SETDEFAULT"] = {
    text = "Set '%s' as the account-wide default fallback profile for unassigned characters?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, profileName)
        AddonControlDB.defaultProfile = profileName
        if ProfileOptionsFrame and ProfileOptionsFrame:IsShown() then
            ProfileOptionsFrame:UpdateDisplay()
        end
        if MainFrame and MainFrame:IsShown() then
            AddonControl:RefreshMainWindow(false)
        end
        PrintMsg("'" .. profileName .. "' is now the default account-wide profile.")
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

StaticPopupDialogs["ADDONCONTROL_NEW_PROFILE"] = {
    text = "Enter a name for the new profile and save your currently checked addons:",
    button1 = SAVE,
    button2 = CANCEL,
    hasEditBox = 1,
    maxLetters = 32,
    OnShow = function(self)
        self.editBox:SetText("")
        self.editBox:SetFocus()
    end,
    OnAccept = function(self)
        local name = self.editBox:GetText():gsub("^%s*(.-)%s*$", "%1")
        if name == "" then
            PrintMsg("Profile name cannot be empty.")
            return
        end
        AddonControlDB.profiles[name] = GetCurrentCheckedAddonsTable()
        AddonControlCharDB.activeProfile = name
        selectedProfileForOptions = name
        if MainFrame and MainFrame:IsShown() then
            AddonControl:RefreshMainWindow(false)
        end
        PrintMsg("Created and saved new profile '" .. name .. "'.")
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        local name = self:GetText():gsub("^%s*(.-)%s*$", "%1")
        if name ~= "" then
            AddonControlDB.profiles[name] = GetCurrentCheckedAddonsTable()
            AddonControlCharDB.activeProfile = name
            selectedProfileForOptions = name
            if MainFrame and MainFrame:IsShown() then
                AddonControl:RefreshMainWindow(false)
            end
            PrintMsg("Created and saved new profile '" .. name .. "'.")
        end
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

StaticPopupDialogs["ADDONCONTROL_DEFAULT_ASSIGNED"] = {
    text = "No valid addon profile was set for this character.\n\nDefault profile '%s' has been assigned. Reload UI now to apply its addons?",
    button1 = "Reload UI",
    button2 = "Later",
    OnAccept = function()
        ReloadUI()
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

-- ============================================================================
-- DATA COLLECTION & SORTING
-- ============================================================================
local function GatherAndSortAddons(scanMemory)
    if scanMemory then
        UpdateAddOnMemoryUsage()
    end

    wipe(addonList)
    local totalMem = 0

    for i = 1, GetNumAddOns() do
        local name, title, notes, enabled, loadable, reason = GetAddOnInfo(i)
        local isLoaded = (IsAddOnLoaded(i) == 1)
        local isLOD = (IsAddOnLoadOnDemand(i) == 1)
        local isLocked = AddonControlDB.alwaysLoad[name] and true or false
        local isChecked = isLocked or (enabledState[name] and true or false)
        local mem = isLoaded and GetAddOnMemoryUsage(i) or 0

        if isLoaded then
            totalMem = totalMem + mem
        end

        if isLocked and not isLoaded and not isLOD then
            pendingReload = true
        end

        table.insert(addonList, {
            index = i,
            name = name,
            title = title or name,
            cleanTitle = StripColors(title or name):lower(),
            notes = notes,
            loadable = loadable,
            reason = reason,
            isLoaded = isLoaded,
            isLOD = isLOD,
            isLocked = isLocked,
            isChecked = isChecked,
            memory = mem,
        })
    end

    table.sort(addonList, function(a, b)
        if sortColumn == "name" then
            if a.cleanTitle == b.cleanTitle then
                return a.index < b.index
            end
            if sortAscending then
                return a.cleanTitle < b.cleanTitle
            else
                return a.cleanTitle > b.cleanTitle
            end
        else
            if a.isLoaded ~= b.isLoaded then
                return a.isLoaded
            end
            if a.memory == b.memory then
                return a.cleanTitle < b.cleanTitle
            end
            if sortAscending then
                return a.memory < b.memory
            else
                return a.memory > b.memory
            end
        end
    end)

    return totalMem
end

-- ============================================================================
-- PANEL C: PROFILE OPTIONS PANEL (Load / Save / Set Default / Delete + Back)
-- ============================================================================
local function CreateProfileOptionsPanel()
    local f = CreateFrame("Frame", "AddonControlProfileOptionsFrame", UIParent)
    f.panelTitle = "Profile Options"
    f:SetSize(320, 280)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    f:Hide()
    tinsert(UISpecialFrames, f:GetName())

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)

    local backBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    backBtn:SetSize(150, 22)
    backBtn:SetPoint("TOPLEFT", 15, -14)
    backBtn:SetText("<< Back")
    backBtn:SetScript("OnClick", function() GoBackFromPanel(f) end)
    f.backBtn = backBtn

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -44)
    f.titleText = title

    local subTitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subTitle:SetPoint("TOP", title, "BOTTOM", 0, -4)
    f.subTitleText = subTitle

    local loadBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    loadBtn:SetSize(240, 28)
    loadBtn:SetPoint("TOP", subTitle, "BOTTOM", 0, -14)
    loadBtn:SetText("Load Profile")
    loadBtn:SetScript("OnClick", function()
        if selectedProfileForOptions then
            StaticPopup_Show("ADDONCONTROL_CONFIRM_LOAD", selectedProfileForOptions, nil, selectedProfileForOptions)
        end
    end)

    local saveBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    saveBtn:SetSize(240, 28)
    saveBtn:SetPoint("TOP", loadBtn, "BOTTOM", 0, -8)
    saveBtn:SetText("Save Current Addons to Profile")
    saveBtn:SetScript("OnClick", function()
        if selectedProfileForOptions then
            StaticPopup_Show("ADDONCONTROL_CONFIRM_SAVE", selectedProfileForOptions, selectedProfileForOptions, selectedProfileForOptions)
        end
    end)

    local defaultBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    defaultBtn:SetSize(240, 28)
    defaultBtn:SetPoint("TOP", saveBtn, "BOTTOM", 0, -8)
    defaultBtn:SetText("Set as Default Profile")
    defaultBtn:SetScript("OnClick", function()
        if selectedProfileForOptions then
            StaticPopup_Show("ADDONCONTROL_CONFIRM_SETDEFAULT", selectedProfileForOptions, nil, selectedProfileForOptions)
        end
    end)
    f.defaultBtn = defaultBtn

    local deleteBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    deleteBtn:SetSize(240, 28)
    deleteBtn:SetPoint("TOP", defaultBtn, "BOTTOM", 0, -8)
    deleteBtn:SetText("Delete Profile")
    deleteBtn:SetScript("OnClick", function()
        if selectedProfileForOptions then
            StaticPopup_Show("ADDONCONTROL_CONFIRM_DELETE", selectedProfileForOptions, nil, selectedProfileForOptions)
        end
    end)

    local footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOM", 0, 14)
    footer:SetText(FOOTER_TEXT)

    function f:UpdateDisplay()
        local pName = selectedProfileForOptions or AddonControlCharDB.activeProfile or AddonControlDB.defaultProfile
        selectedProfileForOptions = pName
        f.titleText:SetText("Profile: |cffffd100" .. tostring(pName) .. "|r")

        local isDefault = (AddonControlDB.defaultProfile == pName)
        local isActive = (AddonControlCharDB.activeProfile == pName)
        local tags = {}
        if isActive then table.insert(tags, "Active on Character") end
        if isDefault then table.insert(tags, "Account Default") end
        f.subTitleText:SetText(#tags > 0 and ("(" .. table.concat(tags, " | ") .. ")") or "Select an action below:")

        if isDefault then
            f.defaultBtn:Disable()
            f.defaultBtn:SetText("Already Default Profile")
        else
            f.defaultBtn:Enable()
            f.defaultBtn:SetText("Set as Default Profile")
        end
    end

    f:SetScript("OnShow", function(self)
        self:UpdateDisplay()
    end)

    ProfileOptionsFrame = f
end

-- ============================================================================
-- PANEL B: REPORT / COPY POPUP WINDOW (Default 3.3.5 Text, Discord, Tab-Delimited)
-- ============================================================================
local function CreateReportPanel()
    local f = CreateFrame("Frame", "AddonControlReportFrame", UIParent)
    f.panelTitle = "Addon Report"
    f:SetSize(500, 420)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    f:Hide()
    tinsert(UISpecialFrames, f:GetName())

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)

    local backBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    backBtn:SetSize(160, 22)
    backBtn:SetPoint("TOPLEFT", 16, -15)
    backBtn:SetText("<< Back")
    backBtn:SetScript("OnClick", function() GoBackFromPanel(f) end)
    f.backBtn = backBtn

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 20, -16)
    title:SetText("Addon Report")

    -- Format Selection Radio Checkboxes
    local fmtLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fmtLabel:SetPoint("TOPLEFT", 20, -48)
    fmtLabel:SetText("Format:")

    local defaultCB = CreateFrame("CheckButton", "AddonControlReportDefaultCB", f, "UICheckButtonTemplate")
    defaultCB:SetSize(24, 24)
    defaultCB:SetPoint("LEFT", fmtLabel, "RIGHT", 8, 0)
    _G[defaultCB:GetName() .. "Text"]:SetText("Default Text")

    local discordCB = CreateFrame("CheckButton", "AddonControlReportDiscordCB", f, "UICheckButtonTemplate")
    discordCB:SetSize(24, 24)
    discordCB:SetPoint("LEFT", defaultCB, "RIGHT", 95, 0)
    _G[discordCB:GetName() .. "Text"]:SetText("Discord")

    local tabCB = CreateFrame("CheckButton", "AddonControlReportTabCB", f, "UICheckButtonTemplate")
    tabCB:SetSize(24, 24)
    tabCB:SetPoint("LEFT", discordCB, "RIGHT", 70, 0)
    _G[tabCB:GetName() .. "Text"]:SetText("Tab-Delimited")

    local scrollBg = CreateFrame("Frame", nil, f)
    scrollBg:SetPoint("TOPLEFT", 18, -74)
    scrollBg:SetPoint("BOTTOMRIGHT", -18, 64)
    scrollBg:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    scrollBg:SetBackdropColor(0, 0, 0, 0.85)

    local scrollFrame = CreateFrame("ScrollFrame", "AddonControlReportScrollFrame", scrollBg, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 8, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 8)

    local editBox = CreateFrame("EditBox", "AddonControlReportEditBox", scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(425)
    editBox:SetAutoFocus(false)
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        GoBackFromPanel(f)
    end)
    scrollFrame:SetScrollChild(editBox)

    local function UpdateFormatCheckboxes()
        defaultCB:SetChecked(reportFormat == "DEFAULT")
        discordCB:SetChecked(reportFormat == "DISCORD")
        tabCB:SetChecked(reportFormat == "TAB")
    end

    local function GenerateReportText()
        UpdateFormatCheckboxes()
        UpdateAddOnMemoryUsage()

        local activeProfileName = AddonControlCharDB.activeProfile
        local profileTable = nil
        if activeProfileName and activeProfileName ~= "Custom" and AddonControlDB.profiles[activeProfileName] then
            profileTable = AddonControlDB.profiles[activeProfileName]
        end

        local profileHeaderName = profileTable and activeProfileName or "None (All Loaded Addons)"
        local reportAddons = {}
        local totalMem = 0

        for i = 1, GetNumAddOns() do
            local name, addonTitle = GetAddOnInfo(i)
            local isLoaded = (IsAddOnLoaded(i) == 1)
            local isLocked = AddonControlDB.alwaysLoad[name] and true or false

            if isLoaded then
                if not profileTable or profileTable[name] or isLocked then
                    local mem = GetAddOnMemoryUsage(i) or 0
                    totalMem = totalMem + mem
                    local cleanTitle = StripColors(addonTitle or name)

                    table.insert(reportAddons, {
                        name = name,
                        title = cleanTitle,
                        sortKey = cleanTitle:lower(),
                        memory = mem,
                        isLocked = isLocked,
                    })
                end
            end
        end

        -- Sort alphabetically by addon title
        table.sort(reportAddons, function(a, b)
            if a.sortKey == b.sortKey then
                return a.name:lower() < b.name:lower()
            end
            return a.sortKey < b.sortKey
        end)

        local lines = {}
        local count = #reportAddons
        local totalMemVal, totalMemUnit = FormatMemorySplit(totalMem)

        if reportFormat == "DEFAULT" then
            table.insert(lines, "============================================================")
            table.insert(lines, string.format("%s - Addon Report", FOOTER_TEXT))
            table.insert(lines, string.format("Profile: %s", profileHeaderName))
            table.insert(lines, string.format("Loaded Addons: %d | Total Memory: %s %s", count, totalMemVal, totalMemUnit))
            table.insert(lines, "------------------------------------------------------------")
            table.insert(lines, "# | Addon Title (Folder) | Size | Unit | Lock Status")
            table.insert(lines, "============================================================")

            for idx, item in ipairs(reportAddons) do
                local memVal, memUnit = FormatMemorySplit(item.memory)
                local lockStr = item.isLocked and " | [Locked - Always Load]" or ""
                table.insert(lines, string.format("%d. %s (%s) | %s | %s%s", idx, item.title, item.name, memVal, memUnit, lockStr))
            end

        elseif reportFormat == "DISCORD" then
            table.insert(lines, string.format("**%s - Addon Report**", FOOTER_TEXT))
            table.insert(lines, string.format("**Profile:** `%s` | **Loaded Addons:** `%d` | **Total Memory:** `%s %s`", profileHeaderName, count, totalMemVal, totalMemUnit))
            table.insert(lines, "```md")
            table.insert(lines, "#  Addon Title (Folder) | Size | Unit | Status")
            table.insert(lines, "------------------------------------------------------------")

            for idx, item in ipairs(reportAddons) do
                local memVal, memUnit = FormatMemorySplit(item.memory)
                local lockStr = item.isLocked and " | [Locked - Always Load]" or ""
                table.insert(lines, string.format("%d. %s (%s) | %s | %s%s", idx, item.title, item.name, memVal, memUnit, lockStr))
            end
            table.insert(lines, "```")

        elseif reportFormat == "TAB" then
            table.insert(lines, string.format("%s\tProfile: %s\tLoaded Addons: %d\tTotal Memory:\t%s\t%s", FOOTER_TEXT, profileHeaderName, count, totalMemVal, totalMemUnit))
            table.insert(lines, "Index\tAddon Title\tFolder Name\tMemory Size\tUnit\tLocked (Always Load)")

            for idx, item in ipairs(reportAddons) do
                local memVal, memUnit = FormatMemorySplit(item.memory)
                local lockStr = item.isLocked and "Locked - Always Load" or "No"
                table.insert(lines, string.format("%d\t%s\t%s\t%s\t%s\t%s", idx, item.title, item.name, memVal, memUnit, lockStr))
            end
        end

        local fullText = table.concat(lines, "\n")
        editBox:SetText(fullText)
        editBox:HighlightText()
        editBox:SetFocus()
    end

    defaultCB:SetScript("OnClick", function()
        reportFormat = "DEFAULT"
        GenerateReportText()
    end)
    discordCB:SetScript("OnClick", function()
        reportFormat = "DISCORD"
        GenerateReportText()
    end)
    tabCB:SetScript("OnClick", function()
        reportFormat = "TAB"
        GenerateReportText()
    end)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("BOTTOMLEFT", 22, 36)
    hint:SetText("|cffffd100Press Ctrl+C to copy to clipboard|r")

    local doneBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    doneBtn:SetSize(90, 24)
    doneBtn:SetPoint("BOTTOMRIGHT", -18, 32)
    doneBtn:SetText("Close")
    doneBtn:SetScript("OnClick", function() GoBackFromPanel(f) end)

    local footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOM", 0, 14)
    footer:SetText(FOOTER_TEXT)

    f:SetScript("OnShow", GenerateReportText)

    ReportFrame = f
end

-- ============================================================================
-- PANEL A: MAIN ADDON CONTROL WINDOW
-- ============================================================================
local function CreateMainPanel()
    local f = CreateFrame("Frame", "AddonControlMainFrame", UIParent)
    f.panelTitle = ADDON_TITLE
    f:SetSize(560, 536)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    f:Hide()
    tinsert(UISpecialFrames, f:GetName())

    -- Header Bar
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)

    local backBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    backBtn:SetSize(120, 22)
    backBtn:SetPoint("TOPLEFT", 16, -14)
    backBtn:SetText("<< Back")
    backBtn:Disable()
    backBtn:SetScript("OnClick", function() GoBackFromPanel(f) end)
    f.backBtn = backBtn

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText(ADDON_TITLE)

    local totalMemText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    totalMemText:SetPoint("TOPRIGHT", -42, -19)
    totalMemText:SetText("Total Memory: 0 KB")
    f.totalMemText = totalMemText

    -- Top Control Bar (Profiles)
    local profileLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    profileLabel:SetPoint("TOPLEFT", 20, -48)
    profileLabel:SetText("Profile:")

    local dropDown = CreateFrame("Frame", "AddonControlProfileDropDown", f, "UIDropDownMenuTemplate")
    dropDown:SetPoint("LEFT", profileLabel, "RIGHT", -8, -2)
    UIDropDownMenu_SetWidth(dropDown, 155)
    f.profileDropDown = dropDown

    -- Default Star Indicator / Button
    local starBtn = CreateFrame("Button", nil, f)
    starBtn:SetSize(22, 22)
    starBtn:SetPoint("LEFT", dropDown, "RIGHT", -8, 2)
    local starTex = starBtn:CreateTexture(nil, "ARTWORK")
    starTex:SetAllPoints()
    starTex:SetTexture("Interface\\COMMON\\ReputationStar")
    starTex:SetTexCoord(0, 0.5, 0, 0.5)
    starBtn.tex = starTex
    starBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local pName = selectedProfileForOptions or AddonControlCharDB.activeProfile or AddonControlDB.defaultProfile
        if AddonControlDB.defaultProfile == pName then
            GameTooltip:SetText("Default Profile", 1, 0.82, 0)
            GameTooltip:AddLine("'" .. tostring(pName) .. "' is currently the account-wide fallback profile for new characters.", 1, 1, 1, true)
        else
            GameTooltip:SetText("Set as Default Profile", 1, 1, 1)
            GameTooltip:AddLine("Click to set '" .. tostring(pName) .. "' as the fallback profile for unassigned characters.", 0.8, 0.8, 0.8, true)
        end
        GameTooltip:Show()
    end)
    starBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    starBtn:SetScript("OnClick", function()
        local pName = selectedProfileForOptions or AddonControlCharDB.activeProfile or AddonControlDB.defaultProfile
        if pName and AddonControlDB.profiles[pName] then
            StaticPopup_Show("ADDONCONTROL_CONFIRM_SETDEFAULT", pName, nil, pName)
        end
    end)
    f.starBtn = starBtn

    -- Profile Action Option List Button
    local profActionsBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    profActionsBtn:SetSize(115, 22)
    profActionsBtn:SetPoint("LEFT", starBtn, "RIGHT", 6, 0)
    profActionsBtn:SetText("Profile Actions...")
    profActionsBtn:SetScript("OnClick", function()
        if not selectedProfileForOptions or not AddonControlDB.profiles[selectedProfileForOptions] then
            selectedProfileForOptions = AddonControlCharDB.activeProfile or AddonControlDB.defaultProfile
        end
        NavigateToPanel(ProfileOptionsFrame, f)
    end)

    -- New Profile Button
    local newProfBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    newProfBtn:SetSize(95, 22)
    newProfBtn:SetPoint("LEFT", profActionsBtn, "RIGHT", 6, 0)
    newProfBtn:SetText("New Profile")
    newProfBtn:SetScript("OnClick", function()
        StaticPopup_Show("ADDONCONTROL_NEW_PROFILE")
    end)

    -- Initialize Profile Dropdown
    UIDropDownMenu_Initialize(dropDown, function(self, level)
        local sortedNames = {}
        for k in pairs(AddonControlDB.profiles) do
            table.insert(sortedNames, k)
        end
        table.sort(sortedNames)

        for _, pName in ipairs(sortedNames) do
            local info = UIDropDownMenu_CreateInfo()
            local isDef = (AddonControlDB.defaultProfile == pName)
            local isAct = (AddonControlCharDB.activeProfile == pName)
            info.text = pName .. (isDef and " |cffffd100[Default]|r" or "")
            info.value = pName
            info.checked = isAct
            info.func = function()
                selectedProfileForOptions = pName
                CloseDropDownMenus()
                AddonControl:UpdateProfileHeaderUI()
                NavigateToPanel(ProfileOptionsFrame, f)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    -- Sortable Column Headers with Hover Tooltips
    local nameHeader = CreateFrame("Button", nil, f)
    nameHeader:SetSize(280, 20)
    nameHeader:SetPoint("TOPLEFT", 58, -78)
    local nameHeaderText = nameHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameHeaderText:SetPoint("LEFT", 0, 0)
    nameHeaderText:SetText("Addon Name (A-Z)")
    nameHeader:SetScript("OnEnter", function(self)
        nameHeaderText:SetTextColor(1, 1, 1)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText("Sort by Addon Name", 1, 0.82, 0)
        GameTooltip:AddLine("Click to sort the addon list alphabetically by name (A-Z or Z-A).", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    nameHeader:SetScript("OnLeave", function()
        nameHeaderText:SetTextColor(1, 0.82, 0)
        GameTooltip:Hide()
    end)
    nameHeader:SetScript("OnClick", function()
        if sortColumn == "name" then
            sortAscending = not sortAscending
        else
            sortColumn = "name"
            sortAscending = true
        end
        AddonControl:RefreshMainWindow(false)
    end)
    f.nameHeaderText = nameHeaderText

    local memHeader = CreateFrame("Button", nil, f)
    memHeader:SetSize(180, 20)
    memHeader:SetPoint("TOPRIGHT", -38, -78)
    local memHeaderText = memHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    memHeaderText:SetPoint("RIGHT", 0, 0)
    memHeaderText:SetText("Memory / Status")
    memHeader:SetScript("OnEnter", function(self)
        memHeaderText:SetTextColor(1, 1, 1)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:SetText("Sort by Addon Memory Size", 1, 0.82, 0)
        GameTooltip:AddLine("Click to sort the addon list by memory usage (High-Low or Low-High).", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    memHeader:SetScript("OnLeave", function()
        memHeaderText:SetTextColor(1, 0.82, 0)
        GameTooltip:Hide()
    end)
    memHeader:SetScript("OnClick", function()
        if sortColumn == "memory" then
            sortAscending = not sortAscending
        else
            sortColumn = "memory"
            sortAscending = false
        end
        AddonControl:RefreshMainWindow(false)
    end)
    f.memHeaderText = memHeaderText

    -- List Backdrop (374px tall -> fits 14 rows of 25px = 350px with 12px top and bottom margin)
    local listBg = CreateFrame("Frame", nil, f)
    listBg:SetPoint("TOPLEFT", 16, -98)
    listBg:SetPoint("BOTTOMRIGHT", -16, 64)
    listBg:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    listBg:SetBackdropColor(0.05, 0.05, 0.05, 0.85)

    -- FauxScrollFrame
    local scrollFrame = CreateFrame("ScrollFrame", "AddonControlFauxScrollFrame", listBg, "FauxScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 4, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", -26, 8)
    scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, function()
            AddonControl:UpdateScrollRows()
        end)
    end)
    f.scrollFrame = scrollFrame

    -- Create Rows
    f.rows = {}
    for i = 1, NUM_ROWS do
        local row = CreateFrame("Button", "AddonControlRow" .. i, listBg)
        row:SetSize(494, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 8, -10 - (i - 1) * ROW_HEIGHT)

        local highlight = row:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        highlight:SetBlendMode("ADD")
        highlight:SetAlpha(0.35)

        -- 1. Padlock ("Always Load") Button using native 3.3.5 LFG Lock Icon
        local lockBtn = CreateFrame("Button", nil, row)
        lockBtn:SetSize(20, 20)
        lockBtn:SetPoint("LEFT", 2, 0)
        lockBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")

        local lockTex = lockBtn:CreateTexture(nil, "ARTWORK")
        lockTex:SetSize(18, 18)
        lockTex:SetPoint("CENTER", 0, 0)
        lockTex:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-LOCK")
        lockBtn.tex = lockTex

        lockBtn:SetScript("OnEnter", function(self)
            local data = row.addonData
            if not data then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if data.name == ADDON_NAME then
                GameTooltip:SetText("Protected Addon Manager", 1, 0.82, 0)
                GameTooltip:AddLine("Addon Control stays locked so you never lock yourself out.", 1, 1, 1, true)
            elseif data.isLocked then
                GameTooltip:SetText("Locked: Always Load on All Characters", 1, 0.82, 0)
                GameTooltip:AddLine("Click the padlock to unlock this addon.", 0.8, 0.8, 0.8, true)
            else
                GameTooltip:SetText("Unlocked (Click to Lock as Always Load)", 1, 1, 1)
                GameTooltip:AddLine("Locked addons are protected across all profiles and automatically enabled on every character.", 0.8, 0.8, 0.8, true)
            end
            GameTooltip:Show()
        end)
        lockBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        lockBtn:SetScript("OnClick", function()
            local data = row.addonData
            if not data or data.name == ADDON_NAME then return end
            if AddonControlDB.alwaysLoad[data.name] then
                AddonControlDB.alwaysLoad[data.name] = nil
            else
                AddonControlDB.alwaysLoad[data.name] = true
                SetAddonEnabledWithDeps(data.index, true, true)
            end
            AddonControl:RefreshMainWindow(false)
        end)
        row.lockBtn = lockBtn

        -- 2. Enable Checkbox
        local checkBtn = CreateFrame("CheckButton", "AddonControlRowCheck" .. i, row, "UICheckButtonTemplate")
        checkBtn:SetSize(22, 22)
        checkBtn:SetPoint("LEFT", lockBtn, "RIGHT", 4, 0)
        checkBtn:SetScript("OnClick", function(self)
            local data = row.addonData
            if not data then return end
            if data.isLocked then
                self:SetChecked(true)
                return
            end
            local newState = self:GetChecked() and true or false
            SetAddonEnabledWithDeps(data.index, newState, false)
            AddonControl:RefreshMainWindow(false)
        end)
        row.checkBtn = checkBtn

        -- 3. Addon Title
        local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetPoint("LEFT", checkBtn, "RIGHT", 4, 0)
        nameText:SetWidth(260)
        nameText:SetJustifyH("LEFT")
        row.nameText = nameText

        -- 4. Status / Memory Text
        local statusText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        statusText:SetPoint("RIGHT", -6, 0)
        statusText:SetWidth(185)
        statusText:SetJustifyH("RIGHT")
        row.statusText = statusText

        -- Row Hover Tooltip
        row:SetScript("OnEnter", function(self)
            local data = self.addonData
            if not data then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(data.title, 1, 1, 1)
            GameTooltip:AddLine("Folder: " .. tostring(data.name), 0.7, 0.7, 0.7)
            local author = GetAddOnMetadata(data.index, "Author")
            local version = GetAddOnMetadata(data.index, "Version")
            if author then GameTooltip:AddLine("Author: " .. author, 0.7, 0.7, 0.7) end
            if version then GameTooltip:AddLine("Version: " .. version, 0.7, 0.7, 0.7) end
            if data.notes and data.notes ~= "" then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(data.notes, 1, 0.82, 0, true)
            end
            local deps = { GetAddOnDependencies(data.index) }
            if #deps > 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Dependencies: " .. table.concat(deps, ", "), 1, 0.5, 0.2, true)
            end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        f.rows[i] = row
    end

    -- Action Buttons Above Footer
    local enableAllBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    enableAllBtn:SetSize(95, 24)
    enableAllBtn:SetPoint("BOTTOMLEFT", 16, 32)
    enableAllBtn:SetText("Enable All")
    enableAllBtn:SetScript("OnClick", function()
        for i = 1, GetNumAddOns() do
            local name = GetAddOnInfo(i)
            if name then
                enabledState[name] = true
                EnableAddOn(name)
            end
        end
        pendingReload = true
        AddonControl:RefreshMainWindow(false)
    end)

    local disableAllBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    disableAllBtn:SetSize(95, 24)
    disableAllBtn:SetPoint("LEFT", enableAllBtn, "RIGHT", 6, 0)
    disableAllBtn:SetText("Disable All")
    disableAllBtn:SetScript("OnClick", function()
        for i = 1, GetNumAddOns() do
            local name = GetAddOnInfo(i)
            if name then
                if AddonControlDB.alwaysLoad[name] then
                    enabledState[name] = true
                    EnableAddOn(name)
                else
                    enabledState[name] = false
                    DisableAddOn(name)
                end
            end
        end
        pendingReload = true
        AddonControl:RefreshMainWindow(false)
    end)

    local reportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    reportBtn:SetSize(95, 24)
    reportBtn:SetPoint("LEFT", disableAllBtn, "RIGHT", 6, 0)
    reportBtn:SetText("Report...")
    reportBtn:SetScript("OnClick", function()
        NavigateToPanel(ReportFrame, f)
    end)

    local reloadBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    reloadBtn:SetSize(130, 24)
    reloadBtn:SetPoint("BOTTOMRIGHT", -16, 32)
    reloadBtn:SetText("Reload UI")
    reloadBtn:SetScript("OnClick", function()
        ReloadUI()
    end)
    f.reloadBtn = reloadBtn

    -- Footer with Version and Author from .toc
    local footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOM", 0, 14)
    footer:SetText(FOOTER_TEXT)

    f:SetScript("OnShow", function()
        AddonControl:RefreshMainWindow(true)
    end)

    MainFrame = f
end

-- ============================================================================
-- UI REFRESH FUNCTIONS
-- ============================================================================
function AddonControl:UpdateProfileHeaderUI()
    if not MainFrame then return end
    local activeName = AddonControlCharDB.activeProfile or AddonControlDB.defaultProfile or "Default"
    local isMod = IsActiveProfileModified()

    local displayLabel = activeName .. (isMod and " |cffff9900(Modified)|r" or "")
    UIDropDownMenu_SetText(MainFrame.profileDropDown, displayLabel)

    local targetCheck = selectedProfileForOptions or activeName
    if AddonControlDB.defaultProfile == targetCheck then
        MainFrame.starBtn.tex:SetVertexColor(1, 0.85, 0, 1)
    else
        MainFrame.starBtn.tex:SetVertexColor(0.45, 0.45, 0.45, 0.8)
    end
end

function AddonControl:UpdateScrollRows()
    if not MainFrame then return end
    local numAddons = #addonList
    FauxScrollFrame_Update(MainFrame.scrollFrame, numAddons, NUM_ROWS, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(MainFrame.scrollFrame)

    for i = 1, NUM_ROWS do
        local row = MainFrame.rows[i]
        local dataIndex = offset + i
        local data = addonList[dataIndex]

        if data then
            row.addonData = data
            row:Show()

            -- Padlock Icon State (Gold & Solid when Locked; Desaturated & Dimmed when Unlocked)
            if data.isLocked then
                row.lockBtn.tex:SetDesaturated(false)
                row.lockBtn.tex:SetVertexColor(1.0, 0.85, 0.0)
                row.lockBtn.tex:SetAlpha(1.0)
                row.checkBtn:SetChecked(true)
                row.checkBtn:Disable()
            else
                row.lockBtn.tex:SetDesaturated(true)
                row.lockBtn.tex:SetVertexColor(0.65, 0.65, 0.65)
                row.lockBtn.tex:SetAlpha(0.4)
                row.checkBtn:Enable()
                row.checkBtn:SetChecked(data.isChecked)
            end

            row.nameText:SetText(data.title)

            if data.isLocked and not data.isLoaded then
                row.nameText:SetTextColor(1.0, 0.6, 0.2)
                row.statusText:SetText("|cffff9933Not Loaded (Will Load on Reload)|r")
            elseif data.isLocked and data.isLoaded then
                row.nameText:SetTextColor(1.0, 0.9, 0.5)
                row.statusText:SetText(FormatMemory(data.memory) .. " |cffffd100[Always]|r")
            elseif data.isLoaded and data.isChecked then
                row.nameText:SetTextColor(1.0, 1.0, 1.0)
                row.statusText:SetText(FormatMemory(data.memory))
            elseif data.isLoaded and not data.isChecked then
                row.nameText:SetTextColor(1.0, 0.85, 0.2)
                row.statusText:SetText("|cffffff33" .. FormatMemory(data.memory) .. " (Will Unload)|r")
            elseif not data.isLoaded and data.isChecked then
                if data.reason == "MISSING" then
                    row.nameText:SetTextColor(1.0, 0.25, 0.25)
                    row.statusText:SetText("|cffff3333Missing Dependency|r")
                elseif data.isLOD then
                    row.nameText:SetTextColor(0.3, 0.85, 1.0)
                    row.statusText:SetText("|cff4dd9ffLoad on Demand|r")
                else
                    row.nameText:SetTextColor(0.25, 1.0, 0.25)
                    row.statusText:SetText("|cff33ff33(Will Load on Reload)|r")
                end
            else
                row.nameText:SetTextColor(0.5, 0.5, 0.5)
                row.statusText:SetText("|cff808080Disabled|r")
            end
        else
            row.addonData = nil
            row:Hide()
        end
    end

    if pendingReload then
        MainFrame.reloadBtn:SetText("|cff33ff33Reload UI *|r")
    else
        MainFrame.reloadBtn:SetText("Reload UI")
    end
end

function AddonControl:RefreshMainWindow(scanMemory)
    if not MainFrame then return end
    local totalMem = GatherAndSortAddons(scanMemory)
    MainFrame.totalMemText:SetText("Total Memory: |cffffd100" .. FormatMemory(totalMem) .. "|r")

    if sortColumn == "name" then
        MainFrame.nameHeaderText:SetText("Addon Name " .. (sortAscending and "(A-Z)" or "(Z-A)"))
        MainFrame.memHeaderText:SetText("Memory / Status")
    else
        MainFrame.nameHeaderText:SetText("Addon Name")
        MainFrame.memHeaderText:SetText("Memory / Status " .. (sortAscending and "(Low-High)" or "(High-Low)"))
    end

    self:UpdateProfileHeaderUI()
    self:UpdateScrollRows()
end

-- ============================================================================
-- MINIMAP BUTTON
-- ============================================================================
local function CreateMinimapButton()
    local btn = CreateFrame("Button", "AddonControlMinimapButton", Minimap)
    btn:SetSize(32, 32)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture("Interface\\Icons\\Trade_Engineering")

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(52, 52)
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    local function UpdateMinimapPosition()
        local angle = math.rad(AddonControlDB.minimapPos or 225)
        local x = math.cos(angle) * 80
        local y = math.sin(angle) * 80
        btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            AddonControlDB.minimapPos = math.deg(math.atan2(cy - my, cx - mx)) % 360
            UpdateMinimapPosition()
        end)
    end)

    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    btn:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            NavigateToPanel(MainFrame, nil)
            NavigateToPanel(ReportFrame, MainFrame)
        else
            if MainFrame:IsShown() then
                MainFrame:Hide()
            else
                NavigateToPanel(MainFrame, nil)
            end
        end
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(ADDON_TITLE, 1, 0.82, 0)
        GameTooltip:AddLine(FOOTER_TEXT, 0.7, 0.7, 0.7)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Left-Click: Toggle Addon Control Panel", 1, 1, 1)
        GameTooltip:AddLine("Right-Click: Open Addon Report", 1, 1, 1)
        GameTooltip:AddLine("Drag: Move Minimap Button", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UpdateMinimapPosition()
end

-- ============================================================================
-- SLASH COMMANDS (/ac and /addoncontrol)
-- ============================================================================
local function SetupSlashCommands()
    local acConflict = false
    for k, v in pairs(_G) do
        if type(k) == "string" and k:match("^SLASH_") and type(v) == "string" and v:lower() == "/ac" then
            acConflict = true
            break
        end
    end

    SLASH_ADDONCONTROL1 = "/addoncontrol"
    if not acConflict then
        SLASH_ADDONCONTROL2 = "/ac"
        activeSlashCommand = "/ac or /addoncontrol"
    else
        activeSlashCommand = "/addoncontrol"
    end

    SlashCmdList["ADDONCONTROL"] = function()
        if MainFrame:IsShown() then
            MainFrame:Hide()
        else
            NavigateToPanel(MainFrame, nil)
        end
    end
end

-- ============================================================================
-- DELAYED CHAT GREETING AFTER PLAYER IS FULLY IN WORLD
-- ============================================================================
local function ScheduleDelayedGreeting(lockedMissingFromMemory)
    local delayElapsed = 0
    AddonControl:SetScript("OnUpdate", function(self, elapsed)
        delayElapsed = delayElapsed + elapsed
        if delayElapsed >= 3.0 then
            self:SetScript("OnUpdate", nil)
            PrintMsg(string.format(
                "%s loaded. Type |cffffd100%s|r or click the Minimap gear icon to manage your addons.",
                FOOTER_TEXT,
                activeSlashCommand
            ))
            if lockedMissingFromMemory then
                PrintMsg("One or more locked 'Always Load' addons are not in memory yet. Open Addon Control and click Reload UI to load them.")
            end
        end
    end)
end

-- ============================================================================
-- INITIALIZATION & AUTO-SYNC
-- ============================================================================
local lockedMissingOnLogin = false

AddonControl:RegisterEvent("PLAYER_LOGIN")
AddonControl:RegisterEvent("PLAYER_ENTERING_WORLD")
AddonControl:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        InitializeDatabase()

        for i = 1, GetNumAddOns() do
            local name = GetAddOnInfo(i)
            local isLoaded = (IsAddOnLoaded(i) == 1)
            local isLOD = (IsAddOnLoadOnDemand(i) == 1)
            local isLocked = AddonControlDB.alwaysLoad[name] and true or false

            if isLoaded then
                enabledState[name] = true
                EnableAddOn(name)
            end

            if isLocked then
                enabledState[name] = true
                EnableAddOn(name)
                if not isLoaded and not isLOD then
                    lockedMissingOnLogin = true
                    pendingReload = true
                end
            end
        end

        local charProfile = AddonControlCharDB.activeProfile
        local notifyFallback = false
        if not charProfile or (charProfile ~= "Custom" and not AddonControlDB.profiles[charProfile]) then
            local fallback = AddonControlDB.defaultProfile or "Default"
            AddonControlCharDB.activeProfile = fallback
            ApplyProfile(fallback)
            notifyFallback = true
        end
        selectedProfileForOptions = AddonControlCharDB.activeProfile

        CreateProfileOptionsPanel()
        CreateReportPanel()
        CreateMainPanel()
        CreateMinimapButton()
        SetupSlashCommands()

        if notifyFallback then
            StaticPopup_Show("ADDONCONTROL_DEFAULT_ASSIGNED", AddonControlCharDB.activeProfile)
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        if loginGreetingPending then
            loginGreetingPending = false
            self:UnregisterEvent("PLAYER_ENTERING_WORLD")
            ScheduleDelayedGreeting(lockedMissingOnLogin)
        end
    end
end)
