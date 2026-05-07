-- SPDX-License-Identifier: GPL-2.0-or-later
---------------------------------------------------------------------------
-- BazChat
-- Chat enhancements for the Baz Suite. Hooks into Blizzard's default
-- chat frames - never replaces them - so combat log, voice, hyperlink
-- protocols, BN whisper routing, ChatThrottle and every other piece
-- of Blizzard chat infrastructure keeps working untouched.
--
-- Each feature is its own self-contained module under Modules/. They
-- register themselves with BazChat:RegisterModule() and the loader in
-- Core/Modules.lua wires them up at PLAYER_LOGIN.
---------------------------------------------------------------------------

local addonName, addon = ...

-- Public API table other modules / addons can call into.
BazChat = {}

-- Internal state shared across BazChat's own files via WoW's per-addon
-- vararg namespace (`local _, addon = ...`). Modules push their specs
-- into addon.modules; the loader in Modules.lua walks that array.
addon.name    = addonName
addon.VERSION = C_AddOns.GetAddOnMetadata(addonName, "Version") or "1"
addon.modules = {}
addon.db      = nil   -- proxied by BazCore once profiles init

---------------------------------------------------------------------------
-- Defaults - one section per module, plus a master enabled toggle.
-- Modules read their own slice via addon.db.profile.<id> so the
-- structure here mirrors the layout of the settings page.
---------------------------------------------------------------------------

local DEFAULTS = {
    enabled = true,

    -- Persistent typed-message history. Up-arrow / down-arrow in any
    -- chat edit box cycles through these. Capped at MAX_LINES inside
    -- Replica/History.lua (50 lines today). Survives /reload and game
    -- restart since this lives in BazChatDB, not in the edit box's
    -- in-session list.
    typedHistory = {},

    -- Per-container geometry (position + size). Each tab is bound to
    -- a dock container via windows[idx].dockID; the dock container's
    -- own pos/size lives here. "dock" is the canonical main dock; any
    -- popped chat window allocates its own entry on pop-out (key like
    -- "pop:1234567890"). Width/height/pos used to live on windows[1];
    -- they migrate into docks.dock on first load post-upgrade so the
    -- user's existing dock geometry is preserved.
    docks = {
        dock = {
            pos    = nil,
            width  = 440,
            height = 120,
        },
    },

    -- Per-replica-window appearance + behavior. Phase 3 has one
    -- window; Phase 5 will expand this to an array indexed by tab
    -- order. The Settings page and the Edit Mode popup BOTH bind to
    -- this block so they stay in sync via the shared DB - the BazBars
    -- pattern (one source of truth, two views).
    windows = {
        [1] = {
            label            = "General",
            -- Container the tab lives in. "dock" is the main dock;
            -- popped containers use ids like "pop:<n>". Drives both
            -- which strip the tab renders in and which container's
            -- frame the chat is anchored to.
            dockID           = "dock",
            -- "GENERAL" = subscribe to every CHAT_MSG_* event.
            -- "GUILD"   = subscribe only to guild-related events.
            -- "COMBAT"  = subscribe only to combat / loot / xp events.
            -- See CHAT_EVENT_GROUPS in Replica/Window.lua.
            eventGroup       = "GENERAL",

            -- Legacy geometry block. Pre-multi-dock these were the
            -- canonical dock geometry; today they are migrated into
            -- DEFAULTS.docks.dock on first load and ignored thereafter.
            -- Kept around so the migration has something to copy from.
            pos              = nil,
            width            = 440,
            height           = 120,

            -- Appearance
            -- alpha   = chat text + scrollbar opacity (the foreground)
            -- bgAlpha = NineSlice chrome panel opacity (the background)
            -- scale   = whole-frame UI scale multiplier
            alpha            = 1.0,
            bgAlpha          = 0.75,
            scale            = 1.0,
            -- Tri-state: "always" / "onscroll" / "never". The
            -- legacy `showScrollbar` boolean is kept for backwards
            -- compat with saves that predate this field; the reader
            -- in Window:ApplySettings checks scrollbarMode first
            -- and falls back to showScrollbar.
            scrollbarMode    = "always",
            showScrollbar    = true,
            -- Background panel visibility. "always" / "onhover" / "never".
            -- Onhover fades the NineSlice chrome in when the cursor is
            -- over the chat, holds 2s, fades out (matching the tab/
            -- scrollbar pattern). Edit Mode forces it visible.
            bgMode           = "always",
            -- Unified background+tabs fade. "off" = bgMode and tabsMode
            -- work independently. "always"/"onhover"/"never" = both
            -- forced to that mode, individual dropdowns greyed out.
            -- The legacy `chromeFadeSync` boolean is migrated to this
            -- field on first load post-upgrade.
            chromeFadeMode   = "always",
            -- Tab strip visibility. "always" / "onhover" / "never".
            -- Onhover fades the strip in when the cursor is over the
            -- chat or any tab, holds 2s after the last hover, fades
            -- out cleanly. Edit Mode forces it visible.
            tabsMode         = "always",
            -- Tab strip "fully visible" opacity. Onhover fades from 0
            -- up to this value (instead of 1.0); always-mode pins to it.
            tabsAlpha        = 1.0,

            -- Behavior - mirrors the SetFading / SetTimeVisible /
            -- SetMaxLines / SetIndentedWordWrap calls in Window:Create.
            fading           = true,
            fadeDuration     = 0.5,
            timeVisible      = 120,
            maxLines         = 500,
            indentedWordWrap = true,
            -- Inter-line pixel spacing applied via SMF:SetSpacing.
            -- Affects EVERY visible row boundary - including wrapped
            -- continuations of a single message - so keep small for
            -- a subtle gap (1-3 px is comfortable). 0 = default tight.
            messageSpacing   = 3,
        },

        -- Guild tab. Same chrome defaults as General, but only
        -- subscribes to GUILD/OFFICER/GUILD_ACHIEVEMENT events so it
        -- only shows guild traffic. Stacked at the same position as
        -- window 1 (Window:Create anchors index>1 relative to [1]).
        [2] = {
            label            = "Guild",
            dockID           = "dock",
            eventGroup       = "GUILD",
            pos              = nil,
            width            = 440,
            height           = 120,
            alpha            = 1.0,
            scale            = 1.0,
            -- Tri-state: "always" / "onscroll" / "never". The
            -- legacy `showScrollbar` boolean is kept for backwards
            -- compat with saves that predate this field; the reader
            -- in Window:ApplySettings checks scrollbarMode first
            -- and falls back to showScrollbar.
            scrollbarMode    = "always",
            showScrollbar    = true,
            -- Background panel visibility. "always" / "onhover" / "never".
            -- Onhover fades the NineSlice chrome in when the cursor is
            -- over the chat, holds 2s, fades out (matching the tab/
            -- scrollbar pattern). Edit Mode forces it visible.
            bgMode           = "always",
            -- Unified background+tabs fade. "off" = bgMode and tabsMode
            -- work independently. "always"/"onhover"/"never" = both
            -- forced to that mode, individual dropdowns greyed out.
            -- The legacy `chromeFadeSync` boolean is migrated to this
            -- field on first load post-upgrade.
            chromeFadeMode   = "always",
            -- Tab strip visibility. "always" / "onhover" / "never".
            -- Onhover fades the strip in when the cursor is over the
            -- chat or any tab, holds 2s after the last hover, fades
            -- out cleanly. Edit Mode forces it visible.
            tabsMode         = "always",
            -- Tab strip "fully visible" opacity. Onhover fades from 0
            -- up to this value (instead of 1.0); always-mode pins to it.
            tabsAlpha        = 1.0,
            fading           = true,
            fadeDuration     = 0.5,
            timeVisible      = 120,
            maxLines         = 500,
            indentedWordWrap = true,
            -- Inter-line pixel spacing applied via SMF:SetSpacing.
            -- Affects EVERY visible row boundary - including wrapped
            -- continuations of a single message - so keep small for
            -- a subtle gap (1-3 px is comfortable). 0 = default tight.
            messageSpacing   = 3,
        },

        -- Trade tab. Mirrors default ChatFrame4 (Loot/Trade) - shows
        -- items / money / currency / tradeskill results, and its
        -- input box is wired to the Trade channel directly when the
        -- player is in one (falls back to SAY otherwise).
        [3] = {
            label            = "Trade",
            dockID           = "dock",
            eventGroup       = "LOOT",
            pos              = nil,
            width            = 440,
            height           = 120,
            alpha            = 1.0,
            scale            = 1.0,
            -- Tri-state: "always" / "onscroll" / "never". The
            -- legacy `showScrollbar` boolean is kept for backwards
            -- compat with saves that predate this field; the reader
            -- in Window:ApplySettings checks scrollbarMode first
            -- and falls back to showScrollbar.
            scrollbarMode    = "always",
            showScrollbar    = true,
            -- Background panel visibility. "always" / "onhover" / "never".
            -- Onhover fades the NineSlice chrome in when the cursor is
            -- over the chat, holds 2s, fades out (matching the tab/
            -- scrollbar pattern). Edit Mode forces it visible.
            bgMode           = "always",
            -- Unified background+tabs fade. "off" = bgMode and tabsMode
            -- work independently. "always"/"onhover"/"never" = both
            -- forced to that mode, individual dropdowns greyed out.
            -- The legacy `chromeFadeSync` boolean is migrated to this
            -- field on first load post-upgrade.
            chromeFadeMode   = "always",
            -- Tab strip visibility. "always" / "onhover" / "never".
            -- Onhover fades the strip in when the cursor is over the
            -- chat or any tab, holds 2s after the last hover, fades
            -- out cleanly. Edit Mode forces it visible.
            tabsMode         = "always",
            -- Tab strip "fully visible" opacity. Onhover fades from 0
            -- up to this value (instead of 1.0); always-mode pins to it.
            tabsAlpha        = 1.0,
            fading           = true,
            fadeDuration     = 0.5,
            timeVisible      = 120,
            maxLines         = 500,
            indentedWordWrap = true,
            -- Inter-line pixel spacing applied via SMF:SetSpacing.
            -- Affects EVERY visible row boundary - including wrapped
            -- continuations of a single message - so keep small for
            -- a subtle gap (1-3 px is comfortable). 0 = default tight.
            messageSpacing   = 3,
        },

        -- Log tab. Subscribes to combat-related events: XP, honor,
        -- faction, skill, achievements, pet info. Read-only (no
        -- edit box). Same set Blizzard ChatFrame2 subscribes to
        -- minus the low-level COMBAT_LOG_EVENT itself.
        [4] = {
            label            = "Log",
            dockID           = "dock",
            eventGroup       = "LOG",
            pos              = nil,
            width            = 440,
            height           = 120,
            alpha            = 1.0,
            scale            = 1.0,
            -- Tri-state: "always" / "onscroll" / "never". The
            -- legacy `showScrollbar` boolean is kept for backwards
            -- compat with saves that predate this field; the reader
            -- in Window:ApplySettings checks scrollbarMode first
            -- and falls back to showScrollbar.
            scrollbarMode    = "always",
            showScrollbar    = true,
            -- Background panel visibility. "always" / "onhover" / "never".
            -- Onhover fades the NineSlice chrome in when the cursor is
            -- over the chat, holds 2s, fades out (matching the tab/
            -- scrollbar pattern). Edit Mode forces it visible.
            bgMode           = "always",
            -- Unified background+tabs fade. "off" = bgMode and tabsMode
            -- work independently. "always"/"onhover"/"never" = both
            -- forced to that mode, individual dropdowns greyed out.
            -- The legacy `chromeFadeSync` boolean is migrated to this
            -- field on first load post-upgrade.
            chromeFadeMode   = "always",
            -- Tab strip visibility. "always" / "onhover" / "never".
            -- Onhover fades the strip in when the cursor is over the
            -- chat or any tab, holds 2s after the last hover, fades
            -- out cleanly. Edit Mode forces it visible.
            tabsMode         = "always",
            -- Tab strip "fully visible" opacity. Onhover fades from 0
            -- up to this value (instead of 1.0); always-mode pins to it.
            tabsAlpha        = 1.0,
            fading           = true,
            fadeDuration     = 0.5,
            timeVisible      = 120,
            maxLines         = 500,
            indentedWordWrap = true,
            -- Inter-line pixel spacing applied via SMF:SetSpacing.
            -- Affects EVERY visible row boundary - including wrapped
            -- continuations of a single message - so keep small for
            -- a subtle gap (1-3 px is comfortable). 0 = default tight.
            messageSpacing   = 3,
        },
    },

    -- Module: copyChat
    -- Adds a small icon to each chat frame's tab area; clicking it
    -- opens BazCore:OpenCopyDialog with the visible chat lines pre-
    -- selected so the user can Ctrl+A / Ctrl+C without WoW's normal
    -- "chat is not selectable" limitation.
    copyChat = {
        enabled  = true,
        iconSize = 16,
    },

    -- Module: channelNames
    -- Hooks ChatFrame*:AddMessage and rewrites bracketed channel
    -- prefixes to short forms. Defaults mirror the conventional
    -- shortenings used by Prat / Chatter so users coming from those
    -- addons feel at home.
    channelNames = {
        enabled = true,
        shortNames = {
            GUILD                 = "g",
            OFFICER               = "o",
            PARTY                 = "p",
            PARTY_LEADER          = "pl",
            RAID                  = "r",
            RAID_LEADER           = "rl",
            RAID_WARNING          = "rw",
            INSTANCE_CHAT         = "i",
            INSTANCE_CHAT_LEADER  = "il",
            BATTLEGROUND          = "bg",
            BATTLEGROUND_LEADER   = "bgl",
            SAY                   = "s",
            YELL                  = "y",
            WHISPER               = "w",
            WHISPER_INFORM        = "to",
            EMOTE                 = "e",
        },
        -- Strip the numeric prefix from custom channels, so
        -- "[1. General]" becomes "[General]". Pure cosmetic.
        stripChannelNumbers = true,
    },

    -- Timestamps: "HH:MM:SS - message" gutter on each line. Format
    -- string is strftime-compatible so "%H:%M" (no seconds) works
    -- too. Separator is whatever character(s) the user picks - the
    -- renderer wraps it with single spaces on each side automatically,
    -- so "-" reads as " - ", "|" reads as " | ", etc. Color is the
    -- {r,g,b,a} for the timestamp + separator; the message body stays
    -- in its native chat color. Re-rendered on replay using each
    -- line's captured time so historic stamps match the original
    -- moment, not "now".
    timestamps = {
        enabled      = true,
        format       = "%I:%M %p",
        separator    = "-",
        color        = { 0.55, 0.55, 0.55, 1 },
        -- When true, hovering the gutter timestamp pops a GameTooltip
        -- with the full readable date (weekday, month, day, year,
        -- 12-hour time). Useful for "when exactly was this sent?"
        -- without cluttering the chat row with a long format.
        hoverTooltip = true,
    },
}

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

local core = BazCore:RegisterAddon(addonName, {
    title         = "BazChat",
    savedVariable = "BazChatDB",
    profiles      = true,
    defaults      = DEFAULTS,

    slash = { "/bazchat", "/bc" },
    commands = {
        copy = {
            desc    = "Copy the visible chat to a popup dialog",
            handler = function()
                if BazChat.OpenCopyForActiveFrame then
                    BazChat:OpenCopyForActiveFrame()
                end
            end,
        },
        toggle = {
            desc    = "Master toggle for all BazChat features",
            handler = function()
                local new = not addon.core:GetSetting("enabled")
                addon.core:SetSetting("enabled", new)
                addon.core:Print("BazChat is " .. (new and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
                if BazChat.RefreshAll then BazChat:RefreshAll() end
            end,
        },

        reset = {
            desc    = "Wipe ALL BazChat saved settings and reload UI",
            handler = function()
                BazChatDB = nil
                if BazCoreDB and BazCoreDB.profiles then
                    for _, p in pairs(BazCoreDB.profiles) do
                        p.BazChat = nil
                    end
                end
                if addon.core then
                    addon.core:Print(
                        "|cffffd100saved settings wiped. Reloading...|r")
                end
                C_Timer.After(0.1, ReloadUI)
            end,
        },

        clear = {
            desc    = "Clear the active chat window (and its persisted history)",
            handler = function()
                local idx = (addon.Window and addon.Window.GetActiveWindowIdx
                             and addon.Window:GetActiveWindowIdx()) or 1
                local f   = addon.Window and addon.Window:Get(idx)
                if f and f.Clear then f:Clear() end
                local p = (addon.db and addon.db.profile)
                    or (addon.core and addon.core.db and addon.core.db.profile)
                if p and p.windows and p.windows[idx] then
                    p.windows[idx].history = nil
                end
            end,
        },

        activeinfo = {
            desc    = "Diagnostic: print active container + chat-routing state",
            handler = function()
                local W = addon.Window
                if not (W and addon.core) then return end
                local p = function(s) addon.core:Print(s) end
                local nameOf = function(f)
                    if not f then return "<nil>" end
                    return f.GetName and f:GetName() or tostring(f)
                end

                p("|cffffd100--- BazChat activeinfo ---|r")
                p("Window.activeContainer = " .. tostring(W.activeContainer))
                p("DEFAULT_CHAT_FRAME  = " .. nameOf(_G.DEFAULT_CHAT_FRAME))
                p("SELECTED_CHAT_FRAME = " .. nameOf(_G.SELECTED_CHAT_FRAME))
                p("SELECTED_DOCK_FRAME = " .. nameOf(_G.SELECTED_DOCK_FRAME))
                p("LAST_ACTIVE_CHAT_EDIT_BOX = " .. nameOf(_G.LAST_ACTIVE_CHAT_EDIT_BOX))
                p("ACTIVE_CHAT_EDIT_BOX = " .. nameOf(_G.ACTIVE_CHAT_EDIT_BOX))

                local s = W._chatHookStats or {}
                p(string.format(
                    "hooks installed=%s | ChooseBox calls=%d (routed=%d) | OpenChat calls=%d (routed=%d) | ActivateChat calls=%d last=%s",
                    tostring(W._chatRoutingHookInstalled),
                    s.chooseBox or 0, s.chooseBoxRouted or 0,
                    s.openChat or 0, s.openChatRouted or 0,
                    s.activateChat or 0, tostring(s.activateChatLast)))

                local activeIdx = W:GetActiveWindowIdx()
                p("GetActiveWindowIdx()  = " .. tostring(activeIdx))
                local activeWin = W:Get(activeIdx)
                p("active win frame      = " .. nameOf(activeWin))
                p("active win editBox    = "
                  .. nameOf(activeWin and activeWin.editBox))

                if W.docks then
                    for id, inst in pairs(W.docks) do
                        local sel = inst.tabSystem and inst.tabSystem.selectedTabID or "?"
                        p(string.format(
                            "  dock[%s] frame=%s selectedTabID=%s",
                            id, nameOf(inst.frame), tostring(sel)))
                    end
                end
            end,
        },

        histcheck = {
            desc    = "Diagnose typed-message history state",
            handler = function()
                if not addon.core then return end
                local p = (addon.db and addon.db.profile)
                    or (addon.core and addon.core.db and addon.core.db.profile)
                if not p then
                    addon.core:Print("|cffff8800histcheck:|r profile not available")
                    return
                end
                local list = p.typedHistory
                local n = list and #list or 0
                addon.core:Print(string.format(
                    "|cffffd100histcheck:|r typedHistory has %d entries", n))
                if n > 0 then
                    -- Print last 3 entries (truncated to 50 chars). Safe
                    -- because these are messages the player typed
                    -- themselves - never secret strings.
                    for i = math.max(1, n - 2), n do
                        local s = list[i] or ""
                        if #s > 50 then s = s:sub(1, 50) .. "..." end
                        addon.core:Print(string.format("  [%d] %s", i, s))
                    end
                end
                -- Active editbox state.
                local tid = (addon.Window and addon.Window.GetActiveWindowIdx
                             and addon.Window:GetActiveWindowIdx()) or 1
                local f   = addon.Window and addon.Window:Get(tid)
                if f and f.editBox then
                    local altMode = f.editBox.GetAltArrowKeyMode
                        and f.editBox:GetAltArrowKeyMode() or "?"
                    local hasFocus = f.editBox.HasFocus
                        and f.editBox:HasFocus() or false
                    local nativeCount = f.editBox.GetHistoryLines
                        and f.editBox:GetHistoryLines() or "?"
                    addon.core:Print(string.format(
                        "  editBox tab=%d altArrowKeyMode=%s focused=%s nativeHistCount=%s",
                        tid, tostring(altMode), tostring(hasFocus),
                        tostring(nativeCount)))
                end
            end,
        },

    },

    minimap = {
        label = "BazChat",
        icon  = 2056011,   -- ui_chat
    },

    onReady = function(self)
        addon.db   = self.db
        addon.core = self           -- expose BazCore addon obj for modules
        if BazChat.InitModules then
            BazChat:InitModules()
        end
    end,
})

-- Stash the BazCore-returned object early so other Core/* files can
-- reach :GetSetting / :Print / :db before onReady fires.
addon.core = core

-- Top-level "/clearchat" and "/cc" slash commands as shortcuts to
-- "/bc clear". Most users expect a one-word slash for clearing chat.
-- We avoid claiming "/clear" because that's commonly used by other
-- addons. The handler reuses the same logic as the /bc clear sub-cmd.
local function ClearActiveTab()
    local idx = (addon.Window and addon.Window.GetActiveWindowIdx
                 and addon.Window:GetActiveWindowIdx()) or 1
    local f   = addon.Window and addon.Window:Get(idx)
    if f and f.Clear then f:Clear() end
    local p = (addon.db and addon.db.profile)
        or (addon.core and addon.core.db and addon.core.db.profile)
    if p and p.windows and p.windows[idx] then
        p.windows[idx].history = nil
    end
end
SLASH_BAZCHATCLEAR1 = "/clearchat"
SLASH_BAZCHATCLEAR2 = "/cc"
SlashCmdList["BAZCHATCLEAR"] = ClearActiveTab
