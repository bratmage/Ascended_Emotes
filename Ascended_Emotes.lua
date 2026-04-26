local ADDON_NAME = ...

local AscendedEmotes = CreateFrame("Frame")
_G[ADDON_NAME] = AscendedEmotes

local MAX_CHAT_BYTES = 255
local EMOTE_CONTINUATION_PREFIX = "|| "
local SEND_INTERVAL = 0.35

local queue = {}
local activeEntry
local hooksInstalled
local originalOnEnterPressed = {}
local onChatEditShow
local elvUIBubblePatched
local slashChatTypes = {
    s = "SAY",
    say = "SAY",
    e = "EMOTE",
    em = "EMOTE",
    me = "EMOTE",
    emote = "EMOTE",
    yell = "YELL",
    y = "YELL",
    p = "PARTY",
    party = "PARTY",
    g = "GUILD",
    guild = "GUILD",
    raid = "RAID",
    ra = "RAID",
    i = "INSTANCE_CHAT",
    bg = "BATTLEGROUND",
}

local function trimTrailingSpaces(text)
    return (text:gsub("%s+$", ""))
end

local function normalizeManualBreaks(text)
    if not text or text == "" then
        return text
    end

    return text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\\n", "\n")
end

local function usesTRP3EmoteSuppression(text)
    return text:sub(-1) == "|"
end

local function stripTRP3EmoteSuppression(text)
    if usesTRP3EmoteSuppression(text) then
        return text:sub(1, -2), true
    end

    return text, false
end

local function shouldSplitMessage(text)
    text = normalizeManualBreaks(text)

    if not text or text == "" then
        return false
    end

    if text:find("\n", 1, true) then
        return true
    end

    return string.len(text) > MAX_CHAT_BYTES
end

local function parseSlashChatMessage(text, defaultLanguage)
    if not text or text:sub(1, 1) ~= "/" then
        return nil
    end

    local command, body = text:match("^/(%S+)%s*(.-)$")
    if not command then
        return nil
    end

    local chatType = slashChatTypes[string.lower(command)]
    if not chatType or body == "" then
        return nil
    end

    return {
        chatType = chatType,
        message = body,
        language = defaultLanguage,
        target = nil,
    }
end

local function getChunk(text, startIndex, maxBytes)
    if startIndex > #text then
        return nil
    end

    -- This right here is for manual linebreaks. it lets the user use \n to  break a chat message before reaching the 255 character. gotta add it to the readme or ill be the only one using it.
	-- lets be real. ill be the only one using it. i added this for me.
    if text:sub(startIndex, startIndex) == "\n" then
        return startIndex + 1, ""
    end

    local limit = math.min(#text, startIndex + maxBytes - 1)
    local newlineAt = text:find("\n", startIndex, true)
    if newlineAt and newlineAt <= limit then
        return newlineAt + 1, trimTrailingSpaces(text:sub(startIndex, newlineAt - 1))
    end

    if limit == #text then
        return #text + 1, text:sub(startIndex)
    end

    -- pretty simply logic to use whitespace to not cut off words, but will still do so if the textline itself is longer than 255 characters
    local splitAt
    for i = startIndex, limit do
        if text:sub(i, i):match("%s") then
            splitAt = i
        end
    end

    if splitAt and splitAt >= startIndex then
        return splitAt + 1, trimTrailingSpaces(text:sub(startIndex, splitAt - 1))
    end

    return limit + 1, text:sub(startIndex, limit)
end

local function buildChunks(text, chatType)
    local chunks = {}
    local strippedText = normalizeManualBreaks(stripTRP3EmoteSuppression(text))
    local startIndex = 1
    local chunkIndex = 1

    while startIndex and startIndex <= #strippedText do
        local maxBytes = MAX_CHAT_BYTES
        -- stealing a bit from TotalRP3, this is how subsequent messages in an emote do not display the character's name
        if chatType == "EMOTE" and chunkIndex > 1 then
            maxBytes = maxBytes - string.len(EMOTE_CONTINUATION_PREFIX)
        end

        local nextIndex, chunk = getChunk(strippedText, startIndex, maxBytes)
        if not nextIndex then
            break
        end

        if chunk ~= "" then
            table.insert(chunks, chunk)
            chunkIndex = chunkIndex + 1
        end

        startIndex = nextIndex
    end

    return chunks
end

local function sendChunk(entry, chunk, isContinuation)
    if entry.chatType == "EMOTE" and isContinuation then
        chunk = EMOTE_CONTINUATION_PREFIX .. chunk
    end

    if entry.chatType == "WHISPER" then
        ChatEdit_SetLastToldTarget(entry.target)
        SendChatMessage(chunk, entry.chatType, entry.language, entry.target)
    elseif entry.chatType == "CHANNEL" then
        SendChatMessage(chunk, entry.chatType, entry.language, entry.target)
    else
        SendChatMessage(chunk, entry.chatType, entry.language)
    end
end

local function startNextQueuedMessage()
    if activeEntry or #queue == 0 then
        return
    end

    activeEntry = table.remove(queue, 1)
    activeEntry.nextSendAt = 0

    -- this is the lil delay. dont want to get the server mad for chat throttling but this also beats the spamming enter key from emote splitter retail. can change it up if we get issues later. editable in the locals.
    AscendedEmotes:SetScript("OnUpdate", function(_, elapsed)
        if not activeEntry then
            AscendedEmotes:SetScript("OnUpdate", nil)
            return
        end

        activeEntry.nextSendAt = activeEntry.nextSendAt - elapsed
        if activeEntry.nextSendAt > 0 then
            return
        end

        local chunk = table.remove(activeEntry.chunks, 1)
        if not chunk then
            activeEntry = nil
            AscendedEmotes:SetScript("OnUpdate", nil)
            startNextQueuedMessage()
            return
        end

        sendChunk(activeEntry, chunk, activeEntry.sentCount > 0)
        activeEntry.sentCount = activeEntry.sentCount + 1
        activeEntry.nextSendAt = SEND_INTERVAL
    end)
end

local function queueChunks(chunks, chatType, language, target)
    table.insert(queue, {
        chunks = chunks,
        chatType = chatType,
        language = language,
        target = target,
        sentCount = 0,
    })

    startNextQueuedMessage()
end

local function queueParsedMessage(editBox, parsed, originalText, addHistory)
    if not parsed or not parsed.chatType or not shouldSplitMessage(parsed.message) then
        return false
    end

    local chunks = buildChunks(parsed.message, parsed.chatType)
    if #chunks <= 1 then
        return false
    end

    queueChunks(chunks, parsed.chatType, parsed.language, parsed.target)

    if addHistory and ChatEdit_AddHistory then
        local previousText = editBox:GetText()
        editBox:SetText(originalText)
        ChatEdit_AddHistory(editBox)
        editBox:SetText(previousText)
    end

    if ChatTypeInfo[parsed.chatType] and ChatTypeInfo[parsed.chatType].sticky == 1 then
        editBox:SetAttribute("stickyType", parsed.chatType)
    end

    ChatEdit_OnEscapePressed(editBox)
    return true
end

local function unlockEditBox(editBox)
    if not editBox then
        return
    end

    if editBox.SetMaxLetters then
        editBox:SetMaxLetters(0)
    end

    if editBox.SetMaxBytes then
        editBox:SetMaxBytes(0)
    end

    if editBox.SetVisibleTextByteLimit then
        editBox:SetVisibleTextByteLimit(0)
    end

    if editBox.SetMultiLine then
        editBox:SetMultiLine(false)
    end
end

local function queueFromEditBox(editBox, text, addHistory)
    local chatType = editBox:GetAttribute("chatType")

    if not chatType or not shouldSplitMessage(text) then
        return false
    end

    local chunks = buildChunks(text, chatType)
    if #chunks <= 1 then
        return false
    end

    local target
    if chatType == "WHISPER" or chatType == "BN_WHISPER" then
        target = editBox:GetAttribute("tellTarget") or editBox.tellTarget
    elseif chatType == "CHANNEL" then
        target = editBox:GetAttribute("channelTarget") or editBox.channelTarget
    end

    queueChunks(chunks, chatType, editBox.language, target)

    if addHistory and ChatEdit_AddHistory then
        ChatEdit_AddHistory(editBox)
    end

    local stickyType = editBox:GetAttribute("chatType")
    if stickyType and ChatTypeInfo[stickyType] and ChatTypeInfo[stickyType].sticky == 1 then
        editBox:SetAttribute("stickyType", stickyType)
    end

    ChatEdit_OnEscapePressed(editBox)
    return true
end

local function handleEnterPressed(editBox)
    unlockEditBox(editBox)

    local text = editBox:GetText() or ""
    if text:sub(1, 1) == "/" then
        local parsed = parseSlashChatMessage(text, editBox.language)
        if parsed and queueParsedMessage(editBox, parsed, text, true) then
            return
        end

        local original = originalOnEnterPressed[editBox]
        if original then
            return original(editBox)
        end
        return
    end

    if queueFromEditBox(editBox, text, true) then
        return
    end

    local original = originalOnEnterPressed[editBox]
    if original and not shouldSplitMessage(text) then
        return original(editBox)
    end
end

local function hookEditBox(editBox)
    if not editBox or originalOnEnterPressed[editBox] then
        return
    end

    unlockEditBox(editBox)
    originalOnEnterPressed[editBox] = editBox:GetScript("OnEnterPressed")
    editBox:SetScript("OnEnterPressed", handleEnterPressed)
    editBox.ascendedEmotesHooked = true
end

local function hookAllChatEditBoxes()
    for i = 1, NUM_CHAT_WINDOWS do
        hookEditBox(_G["ChatFrame" .. i .. "EditBox"])
    end
end

onChatEditShow = function(editBox)
    unlockEditBox(editBox)
end

    -- patch to ElvUI error that I was personally experiencing. Won't fire this or patchElvUIBubbleHandlin without elvui, of course.
local function ensureElvUIBubbleNameFont(frame, engine)
    if not frame or not frame.Name or not frame.Name.GetFont then
        return
    end

    -- ElvUI can occasionally touch the name fontstring before it has a valid font assigned. cant have the error popping up when i personally use elvui! this makes sure it is initialized before SetText("") runs.
    local currentFont = frame.Name:GetFont()
    if currentFont then
        return
    end

    local font, size, outline
    if frame.text and frame.text.GetFont then
        font, size, outline = frame.text:GetFont()
    end

    if not font and engine and engine.Libs and engine.Libs.LSM and engine.private and engine.private.general then
        font = engine.Libs.LSM:Fetch("font", engine.private.general.chatBubbleFont)
        size = engine.private.general.chatBubbleFontSize * 0.85
        outline = engine.private.general.chatBubbleFontOutline
    end

    font = font or STANDARD_TEXT_FONT
    size = size or 12
    outline = outline or ""

    frame.Name:SetFont(font, size, outline)
end

local function patchElvUIBubbleHandling()
    if elvUIBubblePatched then
        return
    end

    local engineRoot = _G.ElvUI
    local engine = engineRoot and engineRoot[1]
    if not engine or not engine.GetModule then
        return
    end

    local misc = engine:GetModule("Misc", true)
    if not misc or not misc.UpdateBubbleBorder then
        return
    end

    local originalUpdateBubbleBorder = misc.UpdateBubbleBorder
    misc.UpdateBubbleBorder = function(self, ...)
        ensureElvUIBubbleNameFont(self, engine)
        return originalUpdateBubbleBorder(self, ...)
    end

    local originalSkinBubble = misc.SkinBubble
    if originalSkinBubble then
        misc.SkinBubble = function(self, frame, ...)
            local result = originalSkinBubble(self, frame, ...)
            ensureElvUIBubbleNameFont(frame, engine)
            return result
        end
    end

    elvUIBubblePatched = true
end

local function installHooks()
    if hooksInstalled then
        return
    end

    patchElvUIBubbleHandling()
    hookAllChatEditBoxes()
    for i = 1, NUM_CHAT_WINDOWS do
        local editBox = _G["ChatFrame" .. i .. "EditBox"]
        if editBox and not editBox.ascendedEmotesShowHooked then
            editBox:HookScript("OnShow", onChatEditShow)
            editBox.ascendedEmotesShowHooked = true
        end
    end
    hooksInstalled = true
end

AscendedEmotes:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        installHooks()
    elseif event == "UPDATE_CHAT_WINDOWS" then
        patchElvUIBubbleHandling()
        hookAllChatEditBoxes()
    end
end)

AscendedEmotes:RegisterEvent("PLAYER_LOGIN")
AscendedEmotes:RegisterEvent("UPDATE_CHAT_WINDOWS")
