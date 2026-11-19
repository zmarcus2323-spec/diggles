-- Guild Recruiter (WoW: Forever)
-- Scans /who in level brackets, collects guildless players, and whispers them
-- a recruitment message on a throttle. Remembers who it contacted so nobody
-- gets whispered twice, and respects "no thanks" replies.
--
-- NOTE: Blizzard requires a hardware event (a click or key press) for every
-- /who query, so each scan is one click of the "Scan" button (or /gr scan,
-- which you can put on a keybind/macro). Whispers themselves are automatic.

local ADDON_NAME = ...
local GR = CreateFrame("Frame")
local DB

local SendChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
local AddFilter = ChatFrame_AddMessageEventFilter
    or (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter)

local DEFAULTS = {
    message = "Hi {name}! <{guild}> is recruiting friendly players for raids, M+ and good chat. Interested? Reply and I'll send an invite :)",
    interval = 3,           -- seconds between whispers (min 2)
    cooldownDays = 30,      -- don't re-whisper the same person for this long
    minLevel = 30,
    maxLevel = 0,           -- 0 = current max level
    step = 5,               -- levels per /who bracket
    zone = "",              -- optional zone filter, e.g. "Orgrimmar"
    classes = {},           -- [CLASSFILE] = true; empty = all classes
    combos = {},            -- learned: [faction][CLASSFILE] = { [race] = true }
    hideOutgoing = true,    -- hide your own recruitment whispers from chat
    contacted = {},         -- [Name-Realm] = time()
    blacklist = {},         -- [Name-Realm] = true
}

local OPT_OUT_WORDS = { "no", "nope", "stop", "nty", "nah", "spam", "not interested", "no thanks", "no thank you", "leave me alone" }
local OPT_IN_WORDS  = { "yes", "yeah", "yep", "sure", "inv", "invite", "ok", "okay", "interested", "y" }

-- state
local brackets = {}         -- pending /who queries
local currentBracket
local whoPending, whoSentAt = false, 0
local queue, queued = {}, {}  -- candidates to whisper
local sending, ticker = false, nil
local sentCount, foundCount = 0, 0
local sentTexts = {}
local lastReplier

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[Guild Recruiter]|r " .. msg)
end

local function CopyDefaults(src, dst)
    for k, v in pairs(src) do
        if dst[k] == nil then
            dst[k] = type(v) == "table" and CopyDefaults(v, {}) or v
        end
    end
    return dst
end

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v)
end

-- Forever is realmless and uses "First Surname" names. /who, whisper events
-- and UnitName may format names slightly differently (realm suffix or not),
-- so we key our records on the lower-cased name with any "-Suffix" removed,
-- and always whisper using the exact name /who gave us.
local function NormalizeName(name)
    if not name or name == "" or IsSecret(name) then return nil end
    name = name:gsub("%-.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return name:lower()
end

-- Classes: { file = "MAGE", name = "Mage" (localized) }
local function AllClasses()
    local list = {}
    if C_CreatureInfo and GetNumClasses then
        for i = 1, GetNumClasses() do
            local ci = C_CreatureInfo.GetClassInfo(i)
            if ci and ci.className and ci.classFile then
                table.insert(list, { file = ci.classFile, name = ci.className })
            end
        end
    end
    return list
end

local function ClassFilterActive()
    return next(DB.classes) ~= nil
end

local function WantedClasses()
    local out = {}
    for _, c in ipairs(AllClasses()) do
        if not ClassFilterActive() or DB.classes[c.file] then table.insert(out, c) end
    end
    return out
end

local function ClassFilterText()
    if not ClassFilterActive() then return "all" end
    local names = {}
    for _, c in ipairs(WantedClasses()) do table.insert(names, c.name) end
    return table.concat(names, ", ")
end

-- Class/race combinations are learned from /who results (per faction, since
-- /who only shows your own faction) and saved, so splits only ever search
-- combinations that really exist in Forever. Nothing is hard-coded.
local function Combos()
    local faction = UnitFactionGroup("player") or "Neutral"
    DB.combos[faction] = DB.combos[faction] or {}
    return DB.combos[faction]
end

local function LearnCombo(info)
    if not info.filename or not info.raceStr or info.raceStr == "" then return end
    local c = Combos()
    c[info.filename] = c[info.filename] or {}
    c[info.filename][info.raceStr] = true
end

-- classes that have actually been seen on your faction (falls back to all)
local function ExistingClasses()
    local combos, out, all = Combos(), {}, AllClasses()
    for _, c in ipairs(all) do
        if combos[c.file] and next(combos[c.file]) then table.insert(out, c) end
    end
    return #out > 0 and out or all
end

-- races that have actually been seen playing this class
local function RacesForClass(classFile)
    local out = {}
    for race in pairs(Combos()[classFile] or {}) do table.insert(out, race) end
    table.sort(out)
    return out
end

local function BracketText(b)
    local t = b.lo == b.hi and tostring(b.lo) or (b.lo .. "-" .. b.hi)
    if b.class then t = t .. " " .. b.class end
    if b.race then t = t .. " " .. b.race end
    return t
end

local function FirstName(name)
    return (name or ""):match("^[^%s%-]+") or name or ""
end

local function MaxLevel()
    if DB.maxLevel and DB.maxLevel > 0 then return DB.maxLevel end
    if GetMaxLevelForPlayerExpansion then return GetMaxLevelForPlayerExpansion() end
    return MAX_PLAYER_LEVEL or 60
end

local function HasWord(text, words)
    text = " " .. text:lower():gsub("[%p]", " "):gsub("%s+", " ") .. " "
    for _, w in ipairs(words) do
        if text:find(" " .. w .. " ", 1, true) then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- UI refresh (defined later)
---------------------------------------------------------------------------
local UI = {}
local function Refresh()
    if not UI.frame then return end
    local nb = brackets[1]
    UI.next:SetText("Next scan: |cffffffff" .. (nb and BracketText(nb) or ("restart from " .. DB.minLevel)) .. "|r")
    UI.filters:SetText(string.format("Levels |cffffffff%d-%d|r   Classes |cffffffff%s|r   Zone |cffffffff%s|r",
        DB.minLevel, MaxLevel(), ClassFilterText(), DB.zone == "" and "any" or DB.zone))
    UI.stats:SetText(string.format("Found: |cffffffff%d|r   Queued: |cffffffff%d|r   Whispered: |cffffffff%d|r",
        foundCount, #queue, sentCount))
    UI.status:SetText(sending and "|cff33ff99Whispering every " .. DB.interval .. "s|r" or "|cffaaaaaaWhispering paused|r")
    UI.toggle:SetText(sending and "Stop whispering" or "Start whispering")
    UI.invite:SetText(lastReplier and ("Invite " .. lastReplier) or "Invite last replier")
    UI.invite:SetEnabled(lastReplier ~= nil)
end

---------------------------------------------------------------------------
-- Scanning
---------------------------------------------------------------------------
local function BuildBrackets()
    wipe(brackets)
    local lo, hi, step = DB.minLevel, MaxLevel(), math.max(1, DB.step)
    local ranges = {}
    -- start at the minimum level and work up to max level
    local l = lo
    while l <= hi do
        table.insert(ranges, { l, math.min(l + step - 1, hi) })
        l = l + step
    end
    -- with a class filter, each range is searched once per wanted class
    local classes = ClassFilterActive() and WantedClasses() or { false }
    for _, r in ipairs(ranges) do
        for _, c in ipairs(classes) do
            table.insert(brackets, { lo = r[1], hi = r[2], class = c and c.name or nil, classFile = c and c.file or nil })
        end
    end
end

-- Keep the Who window from popping up: temporarily unregister WHO_LIST_UPDATE
-- from every other frame, then restore them shortly after our results arrive.
local mutedFrames = {}
local whoWindowWasOpen = false

local function WhoWindowShown()
    return (WhoFrame and WhoFrame:IsVisible()) or false
end

local function MuteWhoUI()
    if #mutedFrames > 0 then return end
    whoWindowWasOpen = WhoWindowShown()
    local frames = GetFramesRegisteredForEvent and { GetFramesRegisteredForEvent("WHO_LIST_UPDATE") } or {}
    if #frames == 0 and FriendsFrame then frames = { FriendsFrame } end
    for _, f in ipairs(frames) do
        if f ~= GR and f.UnregisterEvent then
            f:UnregisterEvent("WHO_LIST_UPDATE")
            table.insert(mutedFrames, f)
        end
    end
end

local function UnmuteWhoUI()
    for _, f in ipairs(mutedFrames) do f:RegisterEvent("WHO_LIST_UPDATE") end
    wipe(mutedFrames)
    -- safety net: if the window opened anyway and you didn't have it open, close it
    if not whoWindowWasOpen and FriendsFrame and FriendsFrame:IsShown() and WhoWindowShown()
        and not InCombatLockdown() then
        HideUIPanel(FriendsFrame)
    end
end

function GR:ScanNext()
    if whoPending and GetTime() - whoSentAt < 6 then
        Print("Still waiting on the last /who result, give it a few seconds.")
        return
    end
    if #brackets == 0 then BuildBrackets() end
    currentBracket = table.remove(brackets, 1)

    local query = string.format("%d-%d", currentBracket.lo, currentBracket.hi)
    if currentBracket.class then query = query .. ' c-"' .. currentBracket.class .. '"' end
    if currentBracket.race then query = query .. ' r-"' .. currentBracket.race .. '"' end
    if DB.zone ~= "" then query = query .. ' z-"' .. DB.zone .. '"' end

    whoPending, whoSentAt = true, GetTime()
    MuteWhoUI()
    C_FriendList.SetWhoToUi(true)
    -- if the server never answers, don't leave the Who window muted forever
    C_Timer.After(8, function() if whoPending then whoPending = false; UnmuteWhoUI() end end)
    C_FriendList.SendWho(query)
    Refresh()
end

local function AddCandidate(info)
    local key = NormalizeName(info.fullName)
    if not key or queued[key] then return end
    if key == NormalizeName(UnitName("player")) or key == NormalizeName(GetUnitName("player", true)) then return end
    if DB.blacklist[key] then return end
    local last = DB.contacted[key]
    if last and (time() - last) < DB.cooldownDays * 86400 then return end
    if (info.level or 0) < DB.minLevel then return end
    if ClassFilterActive() and info.filename and not DB.classes[info.filename] then return end

    queued[key] = true
    foundCount = foundCount + 1
    table.insert(queue, { key = key, name = info.fullName, level = info.level,
        class = info.classStr, zone = info.area })
end

function GR:WHO_LIST_UPDATE()
    if not whoPending then return end
    whoPending = false
    -- restore after this event has finished dispatching, so the Who window doesn't catch it
    C_Timer.After(0.5, UnmuteWhoUI)

    local num, total = C_FriendList.GetNumWhoResults()
    local before = #queue
    for i = 1, num do
        local info = C_FriendList.GetWhoInfo(i)
        if info then LearnCombo(info) end
        if info and (info.fullGuildName == nil or info.fullGuildName == "") then
            AddCandidate(info)
        end
    end

    -- /who caps at 50 results; split a full bracket into smaller ones
    local b = currentBracket
    if b and (num >= 50 or (total or 0) > num) then
        if b.hi > b.lo then
            -- 1) split a level range into single levels
            for lvl = b.hi, b.lo, -1 do
                table.insert(brackets, 1, { lo = lvl, hi = lvl, class = b.class, classFile = b.classFile })
            end
        elseif not b.class then
            -- 2) split a single level by class (only classes that exist on your faction)
            local classes = ExistingClasses()
            for i = #classes, 1, -1 do
                table.insert(brackets, 1, { lo = b.lo, hi = b.hi, class = classes[i].name, classFile = classes[i].file })
            end
        elseif not b.race and b.classFile then
            -- 3) split level + class by race (only races seen playing that class)
            local races = RacesForClass(b.classFile)
            for i = #races, 1, -1 do
                table.insert(brackets, 1, { lo = b.lo, hi = b.hi, class = b.class, classFile = b.classFile, race = races[i] })
            end
        end
    end

    Print(string.format("Scan %s: %d results, %d new guildless players queued.",
        b and BracketText(b) or "?", num, #queue - before))
    Refresh()
end

---------------------------------------------------------------------------
-- Whispering
---------------------------------------------------------------------------
local function FormatMessage(c)
    local guild = (GetGuildInfo("player") or "our guild"):gsub("%%", "%%%%")
    local msg = DB.message
        :gsub("{name}", (FirstName(c.name):gsub("%%", "%%%%")))
        :gsub("{fullname}", (c.name:gsub("%%", "%%%%")))
        :gsub("{guild}", guild)
        :gsub("{level}", tostring(c.level or ""))
        :gsub("{class}", c.class or "")
        :gsub("{zone}", c.zone or "")
    return msg:sub(1, 255)
end

local function SendNext()
    if InCombatLockdown() or #queue == 0 then return end
    local c = table.remove(queue, 1)
    queued[c.key] = nil
    if DB.blacklist[c.key] then return SendNext() end

    local msg = FormatMessage(c)
    sentTexts[msg] = true
    SendChat(msg, "WHISPER", nil, c.name)
    DB.contacted[c.key] = time()
    sentCount = sentCount + 1
    Refresh()
end

function GR:SetSending(on)
    sending = on
    if ticker then ticker:Cancel(); ticker = nil end
    if on then
        if not IsInGuild() then Print("|cffff5555You're not in a guild — invites won't work.|r") end
        ticker = C_Timer.NewTicker(math.max(2, DB.interval), SendNext)
        SendNext()
    end
    Refresh()
end

---------------------------------------------------------------------------
-- Replies
---------------------------------------------------------------------------
function GR:CHAT_MSG_WHISPER(msg, sender)
    -- Midnight/Forever can hand addons "secret" chat values (mostly in instances); skip those
    if IsSecret(msg) or IsSecret(sender) then return end
    local key = NormalizeName(sender)
    local when = key and DB.contacted[key]
    if not when or time() - when > 3 * 86400 then return end

    if HasWord(msg, OPT_OUT_WORDS) and not HasWord(msg, { "yes", "inv", "sure" }) then
        DB.blacklist[key] = true
        Print(sender .. " declined — added to the do-not-whisper list.")
    else
        lastReplier = sender
        local hint = HasWord(msg, OPT_IN_WORDS) and " |cff33ff99(looks like a yes!)|r" or ""
        Print("Reply from |cffffffff" .. sender .. "|r: " .. msg .. hint
            .. "  — type |cffffff00/gr inv|r or click Invite.")
        PlaySound(SOUNDKIT and SOUNDKIT.TELL_MESSAGE or 3081)
    end
    Refresh()
end

function GR:InviteLast()
    if not lastReplier then Print("Nobody has replied yet.") return end
    if C_GuildInfo and C_GuildInfo.Invite then C_GuildInfo.Invite(lastReplier) else GuildInvite(lastReplier) end
    Print("Guild invite sent to " .. lastReplier .. ".")
    lastReplier = nil
    Refresh()
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------
local function BuildUI()
    local f = CreateFrame("Frame", "GuildRecruiterFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(420, 270)
    f:SetPoint("CENTER")
    f:SetMovable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    f:Hide()
    tinsert(UISpecialFrames, "GuildRecruiterFrame")

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("TOP", 0, -5)
    f.title:SetText("Guild Recruiter")

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 16, -34)
    label:SetText("Message — {name} {fullname} {guild} {level} {class} {zone} (Enter saves)")

    local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    eb:SetSize(380, 22)
    eb:SetPoint("TOPLEFT", 22, -50)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(255)
    eb:SetScript("OnShow", function(self) self:SetText(DB.message); self:SetCursorPosition(0) end)
    eb:SetScript("OnEnterPressed", function(self)
        DB.message = self:GetText(); self:ClearFocus(); Print("Message saved.")
    end)
    eb:SetScript("OnEscapePressed", function(self) self:SetText(DB.message); self:ClearFocus() end)

    local scan = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    scan:SetSize(160, 26)
    scan:SetPoint("TOPLEFT", 16, -86)
    scan:SetText("Scan next bracket")
    scan:SetScript("OnClick", function() GR:ScanNext() end)

    UI.next = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    UI.next:SetPoint("LEFT", scan, "RIGHT", 12, 0)

    UI.toggle = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    UI.toggle:SetSize(160, 26)
    UI.toggle:SetPoint("TOPLEFT", scan, "BOTTOMLEFT", 0, -8)
    UI.toggle:SetScript("OnClick", function() GR:SetSending(not sending) end)

    UI.status = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    UI.status:SetPoint("LEFT", UI.toggle, "RIGHT", 12, 0)

    UI.invite = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    UI.invite:SetSize(160, 26)
    UI.invite:SetPoint("TOPLEFT", UI.toggle, "BOTTOMLEFT", 0, -8)
    UI.invite:SetScript("OnClick", function() GR:InviteLast() end)

    local clear = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clear:SetSize(160, 26)
    clear:SetPoint("LEFT", UI.invite, "RIGHT", 12, 0)
    clear:SetText("Clear queue")
    clear:SetScript("OnClick", function() wipe(queue); wipe(queued); Refresh() end)

    UI.filters = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    UI.filters:SetPoint("BOTTOMLEFT", 16, 50)

    UI.stats = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    UI.stats:SetPoint("BOTTOMLEFT", 16, 30)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", 16, 12)
    hint:SetText("Tip: bind /gr scan to a key and tap it every few seconds. /gr help")

    f:SetScript("OnShow", Refresh)
    UI.frame = f
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local HELP = {
    "/gr — show/hide window",
    "/gr scan — run the next /who scan (works in a macro/keybind)",
    "/gr start | stop — start/stop whispering the queue",
    "/gr msg <text> — set message ({name}=first name, {fullname}, {guild}, {level}, {class}, {zone})",
    "/gr test — whisper the message to yourself",
    "/gr levels <min>-<max> [step] — level range, e.g. /gr levels 30-60 (max 0 = level cap)",
    "/gr zone <name> | off — only scan a zone",
    "/gr classes <class> [class...] | all — only recruit these classes, e.g. /gr classes priest druid",
    "/gr interval <seconds> — delay between whispers (min 2)",
    "/gr cooldown <days> — don't re-whisper someone for N days",
    "/gr inv — guild invite the last person who replied",
    "/gr block <Name> — never whisper this person",
    "/gr hide on|off — hide your outgoing recruitment whispers",
    "/gr reset — forget who has been contacted",
    "/gr combos — show learned class/race combinations (/gr combos reset to relearn)",
}

SLASH_GUILDRECRUITER1 = "/gr"
SLASH_GUILDRECRUITER2 = "/guildrecruiter"
SlashCmdList.GUILDRECRUITER = function(input)
    local cmd, rest = input:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "" then
        UI.frame:SetShown(not UI.frame:IsShown())
    elseif cmd == "scan" then
        GR:ScanNext()
    elseif cmd == "start" then
        GR:SetSending(true)
    elseif cmd == "stop" then
        GR:SetSending(false)
    elseif cmd == "msg" and rest ~= "" then
        DB.message = rest:sub(1, 255); Print("Message set: " .. DB.message)
    elseif cmd == "test" then
        local me = UnitName("player")
        SendChat(FormatMessage({ name = me, level = UnitLevel("player"),
            class = UnitClass("player"), zone = GetZoneText() }), "WHISPER", nil, me)
    elseif cmd == "levels" then
        -- accepts "30 60", "30-60", "30 0", "30" and an optional step: "30-60 1"
        local nums = {}
        for n in rest:gmatch("%d+") do table.insert(nums, tonumber(n)) end
        local a, b, s = nums[1], nums[2] or 0, nums[3]
        if a then
            DB.minLevel, DB.maxLevel = a, b
            if s then DB.step = math.max(1, s) end
            wipe(brackets)
            Print(string.format("Levels %d-%d, step %d.", DB.minLevel, MaxLevel(), DB.step))
        else Print("Usage: /gr levels 30-60  (or /gr levels 30-60 1 to scan one level at a time)") end
    elseif cmd == "zone" then
        DB.zone = (rest == "" or rest:lower() == "off") and "" or rest
        wipe(brackets)
        Print(DB.zone == "" and "Zone filter off." or ("Zone filter: " .. DB.zone))
    elseif cmd == "classes" or cmd == "class" then
        local words = rest:lower()
        if words == "" or words == "all" or words == "off" then
            wipe(DB.classes)
        else
            local all, matched = AllClasses(), {}
            for w in words:gmatch("%S+") do
                local hit
                for _, c in ipairs(all) do
                    local n = c.name:lower():gsub("%s", "")
                    if c.file:lower() == w or n == w or n:sub(1, #w) == w then hit = c; break end
                end
                if hit then matched[hit.file] = true else Print("Unknown class: " .. w) end
            end
            if next(matched) then wipe(DB.classes); for k in pairs(matched) do DB.classes[k] = true end end
        end
        wipe(brackets)
        Print("Classes: " .. ClassFilterText())
    elseif cmd == "interval" and tonumber(rest) then
        DB.interval = math.max(2, tonumber(rest))
        if sending then GR:SetSending(true) end
        Print("Whisper interval: " .. DB.interval .. "s")
    elseif cmd == "cooldown" and tonumber(rest) then
        DB.cooldownDays = tonumber(rest); Print("Re-whisper cooldown: " .. DB.cooldownDays .. " days")
    elseif cmd == "inv" or cmd == "invite" then
        GR:InviteLast()
    elseif cmd == "block" and rest ~= "" then
        DB.blacklist[NormalizeName(rest)] = true; Print("Blocked " .. rest)
    elseif cmd == "hide" then
        DB.hideOutgoing = rest:lower() ~= "off"; Print("Hide outgoing whispers: " .. tostring(DB.hideOutgoing))
    elseif cmd == "combos" then
        if rest:lower() == "reset" then
            wipe(Combos()); Print("Learned combinations cleared.")
        else
            local any = false
            for _, c in ipairs(AllClasses()) do
                local races = RacesForClass(c.file)
                if #races > 0 then any = true; Print(c.name .. ": " .. table.concat(races, ", ")) end
            end
            if not any then Print("Nothing learned yet — run a few scans first.") end
        end
    elseif cmd == "reset" then
        wipe(DB.contacted); Print("Contacted list cleared.")
    else
        for _, line in ipairs(HELP) do Print(line) end
    end
    Refresh()
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------
GR:SetScript("OnEvent", function(self, event, ...)
    if self[event] then self[event](self, ...) end
end)

function GR:ADDON_LOADED(name)
    if name ~= ADDON_NAME then return end
    GuildRecruiterDB = CopyDefaults(DEFAULTS, GuildRecruiterDB or {})
    DB = GuildRecruiterDB

    -- one-time upgrades of settings saved by older versions
    local v = DB.settingsVersion or 0
    if v < 2 and DB.minLevel < 30 then DB.minLevel = 30 end   -- old default was 10
    if v < 3 then DB.interval = 3 end                          -- old default was 12s
    DB.settingsVersion = 3

    -- prune old contact records so SavedVariables don't grow forever
    local cutoff = time() - math.max(DB.cooldownDays, 1) * 86400
    for k, t in pairs(DB.contacted) do if t < cutoff then DB.contacted[k] = nil end end

    if AddFilter then
        AddFilter("CHAT_MSG_WHISPER_INFORM", function(_, _, msg)
            if IsSecret(msg) then return false end
            return DB.hideOutgoing and sentTexts[msg] or false
        end)
    end

    BuildUI()
    self:RegisterEvent("WHO_LIST_UPDATE")
    self:RegisterEvent("CHAT_MSG_WHISPER")
    self:UnregisterEvent("ADDON_LOADED")
    Print("Loaded. Type |cffffff00/gr|r to open.")
end

GR:RegisterEvent("ADDON_LOADED")
