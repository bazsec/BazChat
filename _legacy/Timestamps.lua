---------------------------------------------------------------------------
-- BazChat Module: Timestamps
--
-- Optional [HH:MM] (or any strftime format) prefix on each chat line.
-- Hooks the same per-frame AddMessage hook the ChannelNames module
-- uses - both modifications compose into a single new line by the
-- time it lands in the chat frame.
--
-- Default format: "%H:%M" (24-hour). Color: subtle grey wrap so the
-- timestamp doesn't compete visually with the message itself. Both
-- configurable in the settings page.
---------------------------------------------------------------------------

local addonName, addon = ...

local M = {
    id    = "timestamps",
    label = "Timestamps",
}

-- Cached at Refresh time so the hot path doesn't reach into the DB
-- per line. The Refresh() entry point is called whenever the user
-- changes a setting, so this stays fresh.
local active = {
    enabled  = false,
    format   = "%H:%M",
    -- Pre-built color escape: |cAARRGGBB so we can prepend it cheaply.
    colorOpen  = "|cff8c8c8c",
    colorClose = "|r",
}

local function ToColorCode(rgba)
    if type(rgba) ~= "table" then return "|cff8c8c8c" end
    local r = math.floor((rgba[1] or 0.5) * 255)
    local g = math.floor((rgba[2] or 0.5) * 255)
    local b = math.floor((rgba[3] or 0.5) * 255)
    local a = math.floor((rgba[4] or 1.0) * 255)
    return string.format("|c%02x%02x%02x%02x", a, r, g, b)
end

local function ReadConfig()
    local cfg = addon.db and addon.db.profile.timestamps
    if not cfg then return end
    active.enabled    = cfg.enabled and true or false
    active.format     = (cfg.format ~= "" and cfg.format) or "%H:%M"
    active.colorOpen  = ToColorCode(cfg.color)
    active.colorClose = "|r"
end

---------------------------------------------------------------------------
-- AddMessage hook
---------------------------------------------------------------------------

local hookedFrames = {}

local function StampLine(text)
    if not active.enabled then return text end
    if type(text) ~= "string" or text == "" then return text end
    -- Bail on lines that already start with a timestamp-shaped prefix
    -- so a /reload doesn't double-stamp the existing chat history.
    if text:find("^|c%x%x%x%x%x%x%x%x%[%d") then return text end

    local stamp = date(active.format)
    return active.colorOpen .. "[" .. stamp .. "]" .. active.colorClose .. " " .. text
end

local function HookFrame(chatFrame)
    if hookedFrames[chatFrame] then return end
    hookedFrames[chatFrame] = true

    local original = chatFrame.AddMessage
    chatFrame.AddMessage = function(self, text, r, g, b, ...)
        return original(self, StampLine(text), r, g, b, ...)
    end
end

---------------------------------------------------------------------------
-- Module lifecycle
---------------------------------------------------------------------------

function M:Init()
    ReadConfig()
    addon:IterateChatFrames(function(cf) HookFrame(cf) end)
end

function M:Refresh()
    ReadConfig()
    -- Hooks were attached at Init; they now read the cached `active`
    -- table on every line so a settings change is instantly visible
    -- on the next message.
end

BazChat:RegisterModule(M)
