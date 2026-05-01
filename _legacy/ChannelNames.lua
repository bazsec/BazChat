---------------------------------------------------------------------------
-- BazChat Module: Channel Names
--
-- Shortens the bracketed channel prefix in chat lines:
--   [Guild]                 -> [g]
--   [2. Trade - Stormwind]  -> [Trade]   (with stripChannelNumbers)
--   [Party Leader]          -> [pl]
--
-- Implemented via ChatFrame_AddMessageEventFilter on every CHAT_MSG_*
-- event - the recommended Blizzard hook point for per-line text
-- transforms. Filters return the (possibly modified) message back to
-- the chat system; subsequent filters from other addons still see
-- the modified text (or our changes get composed with theirs).
---------------------------------------------------------------------------

local addonName, addon = ...

local M = {
    id    = "channelNames",
    label = "Channel Names",
}

-- Every CHAT_MSG_* event whose default render uses a bracketed channel
-- prefix. We don't need to register CHAT_MSG_SYSTEM, COMBAT_LOG_*,
-- ADDON, etc. - those don't have a prefix.
local EVENTS = {
    "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE", "CHAT_MSG_TEXT_EMOTE",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID",  "CHAT_MSG_RAID_LEADER",  "CHAT_MSG_RAID_WARNING",
    "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "CHAT_MSG_BATTLEGROUND", "CHAT_MSG_BATTLEGROUND_LEADER",
    "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
    "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_BN_WHISPER", "CHAT_MSG_BN_WHISPER_INFORM",
    "CHAT_MSG_CHANNEL",
}

-- Mapping CHAT_MSG_* event suffix -> shortName key in DEFAULTS.
-- Most events line up; the BN_* variants reuse WHISPER's mapping,
-- and the leader/warning variants get their own distinct keys.
local EVENT_TO_KEY = {
    CHAT_MSG_SAY                       = "SAY",
    CHAT_MSG_YELL                      = "YELL",
    CHAT_MSG_EMOTE                     = "EMOTE",
    CHAT_MSG_TEXT_EMOTE                = "EMOTE",
    CHAT_MSG_PARTY                     = "PARTY",
    CHAT_MSG_PARTY_LEADER              = "PARTY_LEADER",
    CHAT_MSG_RAID                      = "RAID",
    CHAT_MSG_RAID_LEADER               = "RAID_LEADER",
    CHAT_MSG_RAID_WARNING              = "RAID_WARNING",
    CHAT_MSG_INSTANCE_CHAT             = "INSTANCE_CHAT",
    CHAT_MSG_INSTANCE_CHAT_LEADER      = "INSTANCE_CHAT_LEADER",
    CHAT_MSG_BATTLEGROUND              = "BATTLEGROUND",
    CHAT_MSG_BATTLEGROUND_LEADER       = "BATTLEGROUND_LEADER",
    CHAT_MSG_GUILD                     = "GUILD",
    CHAT_MSG_OFFICER                   = "OFFICER",
    CHAT_MSG_WHISPER                   = "WHISPER",
    CHAT_MSG_WHISPER_INFORM            = "WHISPER_INFORM",
    CHAT_MSG_BN_WHISPER                = "WHISPER",
    CHAT_MSG_BN_WHISPER_INFORM         = "WHISPER_INFORM",
}

---------------------------------------------------------------------------
-- Filters
--
-- Blizzard delivers the chat line to ChatFrame.lua, which composes a
-- "[Channel] PlayerName: text" string and inserts it via AddMessage.
-- The event filter actually runs BEFORE that composition - it gets
-- the raw payload and can rewrite it. So we don't see the bracket
-- text directly; instead we override the channel prefix lookup.
--
-- Trick: ChatTypeInfo[CHATTYPE].chatStrFormat / CHAT_<TYPE>_GET aren't
-- exposed as override hooks in modern WoW. We use a SUBSTITUTION
-- approach: hook the chat frame's AddMessage and rewrite the final
-- bracketed prefix in the rendered string before it lands. That's
-- the pattern Prat / Chatter use because it's robust across patches.
---------------------------------------------------------------------------

-- Pre-compiled patterns + replacements built at Refresh() so the hot
-- path doesn't reach into addon.db on every line.
local active = {
    -- bracketRewrites = { [longBracketLiteral] = shortBracketLiteral }
    bracketRewrites = {},
    stripNumbers    = false,
}

-- Channel localization-friendly bracket text. The L_ table reads from
-- Blizzard's CHAT_*_GET globals so we work with whatever language the
-- client is in; no hardcoded English strings.
local function GetLongBracketFor(key)
    -- Map of our internal key -> the GLOBALSTRING that holds the
    -- localized "[Guild] " etc. prefix template. Returns the bracket
    -- portion only (without the player name / colon / message).
    local templateName
    if key == "GUILD"               then templateName = "CHAT_GUILD_GET"
    elseif key == "OFFICER"         then templateName = "CHAT_OFFICER_GET"
    elseif key == "PARTY"           then templateName = "CHAT_PARTY_GET"
    elseif key == "PARTY_LEADER"    then templateName = "CHAT_PARTY_LEADER_GET"
    elseif key == "RAID"            then templateName = "CHAT_RAID_GET"
    elseif key == "RAID_LEADER"     then templateName = "CHAT_RAID_LEADER_GET"
    elseif key == "RAID_WARNING"    then templateName = "CHAT_RAID_WARNING_GET"
    elseif key == "INSTANCE_CHAT"        then templateName = "CHAT_INSTANCE_CHAT_GET"
    elseif key == "INSTANCE_CHAT_LEADER" then templateName = "CHAT_INSTANCE_CHAT_LEADER_GET"
    elseif key == "BATTLEGROUND"         then templateName = "CHAT_BATTLEGROUND_GET"
    elseif key == "BATTLEGROUND_LEADER"  then templateName = "CHAT_BATTLEGROUND_LEADER_GET"
    elseif key == "SAY"             then templateName = "CHAT_SAY_GET"
    elseif key == "YELL"            then templateName = "CHAT_YELL_GET"
    elseif key == "EMOTE"           then templateName = "CHAT_EMOTE_GET"
    end
    if not templateName then return nil end

    local template = _G[templateName]
    if type(template) ~= "string" then return nil end
    -- Templates look like "[Guild] %s: " or "[%s] %s: " depending on
    -- locale. We want the literal bracket portion without the player
    -- placeholder / colon. Slice on " %s" - first %s is the player
    -- name placeholder.
    local bracket = template:match("^(%b[])")
    return bracket
end

local function RebuildPatterns()
    local cfg = addon.db and addon.db.profile.channelNames
    if not cfg then return end

    wipe(active.bracketRewrites)
    active.stripNumbers = cfg.stripChannelNumbers and true or false

    for key, short in pairs(cfg.shortNames or {}) do
        local longBracket = GetLongBracketFor(key)
        if longBracket and short and short ~= "" then
            active.bracketRewrites[longBracket] = "[" .. short .. "]"
        end
    end
end

---------------------------------------------------------------------------
-- AddMessage hook - per-frame, lightweight
---------------------------------------------------------------------------

local hookedFrames = {}

local function RewriteLine(text)
    if type(text) ~= "string" then return text end

    -- Static bracket replacements (Guild, Party, etc.). Most lines
    -- only contain at most one prefix, so a single string.find +
    -- gsub is cheap. Patterns are pre-quoted via [%b[]] match so we
    -- can use plain gsub.
    for long, short in pairs(active.bracketRewrites) do
        if text:find(long, 1, true) then
            text = text:gsub(long, short, 1)
            break  -- one prefix per line; bail early
        end
    end

    -- Custom channels: "[1. General - Stormwind]" -> "[General]"
    if active.stripNumbers then
        text = text:gsub("%[%d+%.%s*([^%]:]-)%s*%-[^%]]+%]", "[%1]")
        text = text:gsub("%[%d+%.%s*([^%]]-)%]", "[%1]")
    end

    return text
end

local function HookFrame(chatFrame)
    if hookedFrames[chatFrame] then return end
    hookedFrames[chatFrame] = true

    local original = chatFrame.AddMessage
    chatFrame.AddMessage = function(self, text, r, g, b, ...)
        return original(self, RewriteLine(text), r, g, b, ...)
    end
end

---------------------------------------------------------------------------
-- Module lifecycle
---------------------------------------------------------------------------

function M:Init()
    RebuildPatterns()
    addon:IterateChatFrames(function(cf) HookFrame(cf) end)
end

function M:Refresh()
    -- Re-read the rewrite map from settings. Hooks are already in
    -- place from Init; they pick up the new map on the next line.
    RebuildPatterns()
end

BazChat:RegisterModule(M)
