---------------------------------------------------------------------------
-- BazChat Replica: Window
--
-- A single chat window with the full Blizzard chat chrome:
--   * Visuals via FloatingBorderedFrame (the same backdrop + corner +
--     edge textures the default ChatFrame1 uses)
--   * Edit box via Blizzard's ChatFrameEditBoxTemplate (channel
--     selector, language dropdown, autocomplete, history all included)
--   * MinimalScrollBar on the right edge
--   * Resize grabber, scroll-to-bottom indicator, click-anywhere focus
--   * Mixin(ChatFrameMixin) for the message formatter
--   * A clickable tab anchored above the window
--
-- Template definition lives in Replica/BazChat.xml. We CreateFrame
-- using "BazChatFrameTemplate" then layer the mixin in Lua so we
-- own the event registration order (vs being driven by the template's
-- OnLoad chain, which would call self:OnLoad - a method that doesn't
-- exist on ChatFrameMixin).
---------------------------------------------------------------------------

local addonName, addon = ...

local Window = {}
addon.Window = Window
BazChat.Window = Window   -- public access for /script and other addons

local windows = {}
local tabs    = {}
Window.list = windows
Window.tabs = tabs

---------------------------------------------------------------------------
-- The full set of CHAT_MSG_* events the default chat frame handles.
-- pcall'd at register time so deprecated names (Blizzard removes some
-- across patches - e.g. CHAT_MSG_BATTLEGROUND) skip silently.
---------------------------------------------------------------------------

-- Per-tab chat-event subscription is now driven by Replica/Channels.lua.
-- Each window's saved channels{} table maps to a deduped list of
-- CHAT_MSG_* events; addon.Channels:Subscribe(f, idx) registers them
-- on the chat frame. Right-click on a tab opens the popup that toggles
-- categories live. Old eventGroup field is migrated to channels{} on
-- first load post-upgrade and then ignored.

-- Is the Trade channel currently usable? Use GetZonePVPInfo() - it
-- returns "sanctuary" for major cities (Stormwind / Orgrimmar /
-- Valdrakken / Dornogal / etc.), which is precisely where Trade
-- chat is active. We previously tried C_ChatInfo.IsRegionalService-
-- Available, but that returned true everywhere - it's a "realm
-- supports regional channels" check, not a "regional channel is
-- currently active for me" check.
-- Channel detection (Tabs:IsTradeUsable, Tabs:ApplyChatType) and the
-- TabSystem itself live in Replica/Tabs.lua. Window.lua just calls
-- addon.Tabs:* where it needs them.

-- Hide every texture region on the editbox except our own backdrop.
-- ChatFrameEditBoxTemplate has more chrome layers than just the
-- Left/Mid/Right + focus variants - there's a separate "header
-- shadow" texture and possibly other glow / focus art that re-shows
-- itself on ChatEdit_ActivateChat. Iterating GetRegions catches them
-- all, regardless of name. We protect _bcBg (our background) so it
-- stays visible.
local function HideEditBoxChrome(editBox)
    if not editBox.GetRegions then return end
    for _, region in ipairs({ editBox:GetRegions() }) do
        if region:IsObjectType("Texture") and region ~= editBox._bcBg then
            region:Hide()
        end
    end
end

-- Pure-code fallbacks. Used only if the DB hasn't loaded yet (early
-- in the boot chain) or if `windows[idx]` is missing. The canonical
-- source of truth is `addon.db.profile.windows[idx]` - these match
-- the DEFAULTS in Core/Init.lua exactly.
local FALLBACKS = {
    fontObject       = "ChatFontNormal",
    width            = 440,
    height           = 120,
    alpha            = 1.0,
    bgAlpha          = 0.75,
    bgMode           = "always",
    tabsAlpha        = 1.0,
    chromeFadeMode   = "always",
    scale            = 1.0,
    showScrollbar    = true,
    maxLines         = 500,
    fading           = true,
    fadeDuration     = 0.5,
    timeVisible      = 120,
    indentedWordWrap = true,
    messageSpacing   = 3,
}

-- Safe DB profile accessor. BazCore's onReady (which sets addon.db)
-- runs AFTER QueueForLogin callbacks - so at the time Replica:Start
-- runs, addon.db is nil but addon.core.db is already populated by
-- BazCore. Try addon.db first (the conventional path for after
-- onReady has fired), then fall through to addon.core.db. Setting
-- writes through whichever one we find means the user's lock /
-- alpha / position changes actually persist across /reload.
local function GetProfile()
    if addon.db and addon.db.profile then return addon.db.profile end
    if addon.core and addon.core.db and addon.core.db.profile then
        return addon.core.db.profile
    end
    return nil
end

-- Safe per-window settings accessor. Returns the live profile table
-- when available (so writes propagate to SavedVariables); falls back
-- to FALLBACKS so reads still work if the DB really isn't ready yet.
local function WindowDB(idx)
    local p = GetProfile()
    if p and p.windows then
        return p.windows[idx] or FALLBACKS
    end
    return FALLBACKS
end

---------------------------------------------------------------------------
-- Chrome lives in Replica/Chrome.lua. Window:Create calls
-- addon.Chrome:ApplyDefault(f) and addon.Chrome:Apply(f) for visuals.
-- /bc nine slash logic in Core/Init.lua calls addon.Chrome:Cycle/Set/etc.
---------------------------------------------------------------------------

-- Channel-tab visibility lives in addon.Tabs:UpdateVisibility (Tabs.lua).
-- The dock zone-watcher in Window:CreateDock calls it on zone changes.

---------------------------------------------------------------------------
-- Dock instances
--
-- A "dock instance" is an invisible always-shown Frame that owns its
-- container's position. Every chat window SetAllPoints to its dock
-- instance's frame; the matching TabSystem strip anchors to it; Edit
-- Mode registers each dock (not individual chat windows). So dragging
-- in Edit Mode moves the dock, and every chat window + the tab strip
-- follow rigidly via static anchors. No more "teleport" snapping
-- after a drag of a non-General tab.
--
-- Today there are two kinds of dock instance:
--   id "dock"      - the main dock; created on first call by Window:Create
--   id "pop:<n>"   - a popped-out floating mini-dock; created by PopOut
--
-- Each tab carries a windows[idx].dockID field that tags it to its
-- container. Tabs:AddFor uses that field to add the tab to the right
-- strip; chat windows SetAllPoints to that dockID's frame. Both kinds
-- go through Window:CreateDockInstance(id, opts) so chrome / strip /
-- edit-mode behaviour matches between the dock and any popped window.
--
-- Window.dock stays as a back-compat alias for the main dock's frame
-- (used by AutoHide, CombatLog, TabDrag, the old Tabs:Ensure anchor,
-- and a few slash commands - they all expect the singleton).
---------------------------------------------------------------------------

Window.docks = {}   -- dockID -> instance struct

-- Per-instance settings accessor. Reads from profile.docks[id], creating
-- the slot lazily so writes always have somewhere to land.
local function GetDockSettings(id)
    local p = GetProfile()
    if not p then return nil end
    p.docks = p.docks or {}
    p.docks[id] = p.docks[id] or {}
    return p.docks[id]
end

-- Returns the live profile.windows entry for a window, or nil.
local function WindowProfile(idx)
    local p = GetProfile()
    return p and p.windows and p.windows[idx] or nil
end

-- Resolves a window index's dockID, defaulting to "dock" if the field
-- is missing (pre-migration saves or hand-edited DBs).
local function DockIDForWindow(idx)
    local ws = WindowProfile(idx)
    return (ws and ws.dockID) or "dock"
end

-- All currently-live window indices in a given dock instance.
local function WindowsInDock(id)
    local out = {}
    for idx, _ in pairs(windows) do
        if DockIDForWindow(idx) == id then
            out[#out + 1] = idx
        end
    end
    table.sort(out)
    return out
end

-- The zone-watcher is a singleton concern (one set of WoW events for
-- the whole addon, not per-dock). Lifted out of CreateDockInstance so
-- creating the second dock doesn't double-register events.
local function InstallZoneWatcherOnce()
    if Window._zoneWatcher then return end
    local f = CreateFrame("Frame")
    Window._zoneWatcher = f
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    f:RegisterEvent("ZONE_CHANGED")
    f:RegisterEvent("ZONE_CHANGED_INDOORS")
    f:RegisterEvent("CHANNEL_UI_UPDATE")
    f:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
    f:RegisterEvent("PLAYER_UPDATE_RESTING")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")    -- combat ends
    f:RegisterEvent("PLAYER_REGEN_DISABLED")   -- combat starts
    f:RegisterEvent("GROUP_ROSTER_UPDATE")     -- party/raid change
    -- Watcher body wrapped in securecallfunction so any string ops
    -- it does on potentially-secret chat data (channel names from
    -- cross-realm contexts, etc.) don't taint the dispatch context
    -- shared with other frames' OnEvent scripts. CHAT_MSG_CHANNEL_-
    -- NOTICE is registered here too - the chat frame's MessageEvent-
    -- Handler runs for the SAME event in the same dispatch, and
    -- without isolation our taint contaminates its later secure
    -- calls (RemoveExtraSpaces, ReplaceIconAndGroupExpressions).
    local function ZoneWatcherBody()
        if addon.Tabs then addon.Tabs:UpdateVisibility() end
        if addon.Channels and addon.Channels.RefreshChannelList then
            local p = GetProfile()
            local list = (addon.Window and addon.Window.list) or {}
            for idx, win in pairs(list) do
                local ws = p and p.windows and p.windows[idx]
                if ws then
                    addon.Channels:RefreshChannelList(win, ws)
                end
            end
        end
    end
    local secureCall = securecallfunction
    f:SetScript("OnEvent", function()
        if secureCall then
            secureCall(ZoneWatcherBody)
        else
            ZoneWatcherBody()
        end
    end)
end

-- Factory: build a dock instance with the given id, or return the one
-- already registered. opts honors:
--   label           - override Edit Mode label (defaults to a per-id name)
--   defaultPos      - { point, relPoint, x, y } used when docks[id].pos
--                     is missing (per-id default for fresh popouts)
--   defaultSize     - { w, h } used when docks[id].width/height missing
function Window:CreateDockInstance(id, opts)
    if Window.docks[id] then return Window.docks[id] end
    opts = opts or {}

    local instance = { id = id, _inEditMode = false }
    -- Frame name has to be a valid Lua identifier; dockIDs use ":" so
    -- swap to "_" before stitching it into the global frame name.
    local safeID = (id or "dock"):gsub("[^%w_]", "_")
    local frame = CreateFrame("Frame", "BazChatDock_" .. safeID, UIParent)
    instance.frame = frame
    frame._dockInstance = instance
    -- Mirror _inEditMode onto the frame so back-compat callers that
    -- read Window.dock._inEditMode (AutoHide, syncBg, the Tabs click
    -- callback) keep working without per-instance plumbing.
    frame._inEditMode = false

    -- Read saved size from docks[id], fall back to defaults. Popped
    -- instances get a larger default than the main dock's narrow chat
    -- bar so the floating window has enough room to read messages
    -- without immediately needing a resize.
    local ds = GetDockSettings(id) or {}
    local defaultSize = opts.defaultSize or {}
    local fallbackW = (id == "dock") and FALLBACKS.width  or 420
    local fallbackH = (id == "dock") and FALLBACKS.height or 240
    local sizeW = ds.width  or defaultSize.w or fallbackW
    local sizeH = ds.height or defaultSize.h or fallbackH
    frame:SetSize(sizeW, sizeH)

    -- Read saved position. Per-id defaults: the main dock anchors
    -- BOTTOMLEFT in the typical chat corner; popped instances default
    -- to true screen-center (computed from the frame's actual size so
    -- the offsets stay correct regardless of fallbackW/fallbackH or
    -- a user-customized defaultSize). TOPLEFT anchor specifically -
    -- the BOTTOMRIGHT resize handle needs a fixed top-left corner to
    -- drag against; CENTER-anchored frames behave oddly during
    -- StartSizing.
    local pos = ds.pos
    if pos and pos.point then
        frame:SetPoint(pos.point, _G[pos.relTo or "UIParent"] or UIParent,
            pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    elseif opts.defaultPos and opts.defaultPos.point then
        local d = opts.defaultPos
        frame:SetPoint(d.point, _G[d.relTo or "UIParent"] or UIParent,
            d.relPoint or d.point, d.x or 0, d.y or 0)
    elseif id == "dock" then
        frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 32, 70)
    else
        -- Center the popped window on the screen: TOPLEFT lands at
        -- (screenCenterX - width/2, screenCenterY + height/2) which
        -- puts the frame's geometric center exactly at UIParent's
        -- center.
        frame:SetPoint("TOPLEFT", UIParent, "CENTER",
                       -sizeW / 2, sizeH / 2)
    end

    -- Persist size on every resize. Hooks both manual SetSize calls
    -- and the resize-handle drag (OnSizeChanged fires for both). Round
    -- to ints so the saved values stay clean.
    frame:SetScript("OnSizeChanged", function(self, w, h)
        local d = GetDockSettings(id)
        if not d then return end
        d.width  = math.floor((w or 0) + 0.5)
        d.height = math.floor((h or 0) + 0.5)
    end)

    -- Movable + resizable by Edit Mode and by the chat-frame's
    -- resize-button proxy. Chat windows in this container SetAllPoints
    -- to this frame, so resizing this frame cascades through tabs +
    -- windows + chrome.
    frame:SetMovable(true)
    frame:SetResizable(true)
    -- Intentionally NOT clamped to the screen - the user prefers
    -- being able to drag the chat right up against (or even past)
    -- a screen edge for tucked-away layouts.
    if frame.SetResizeBounds then
        frame:SetResizeBounds(250, 80, 1200, 800)
    end

    Window.docks[id] = instance
    if id == "dock" then Window.dock = frame end   -- back-compat alias

    InstallZoneWatcherOnce()

    -- Register with Edit Mode for drag-to-position + per-frame
    -- settings popup. The settings array is built from the unified
    -- SettingsSpec (Replica/SettingsSpec.lua) via BazCore so this
    -- popup and the Options page read from the same source.
    if BazCore and BazCore.RegisterEditModeFrame then
        local label = opts.label
            or (id == "dock" and "BazChat" or "BazChat: " .. id)

        local actions = {
            { label = "Open BazChat Settings",
              onClick = function()
                  if BazCore.OpenOptionsPanel then
                      BazCore:OpenOptionsPanel("BazChat")
                  end
              end },
            { label = "Revert Changes", builtin = "revert" },
        }
        -- Popped instances also expose a "Pop in" path so the user
        -- can re-dock from the edit-mode popup without going through
        -- the tab context menu.
        if id ~= "dock" then
            table.insert(actions, 1, {
                label = "Pop all tabs back to dock",
                onClick = function() Window:DockInstance(id) end,
            })
        end

        BazCore:RegisterEditModeFrame(frame, {
            label       = label,
            addonName   = "BazChat",
            positionKey = false,

            settings = (BazCore.BuildEditModeArrayFromSpec
                and BazCore:BuildEditModeArrayFromSpec("BazChat")) or {},

            actions = actions,

            onPositionChanged = function(f)
                local point, _, relPoint, x, y = f:GetPoint()
                if not point then return end
                local d = GetDockSettings(id)
                if d then
                    d.pos = { point = point, relPoint = relPoint,
                              x = x, y = y }
                end
            end,
            onEnter = function()
                instance._inEditMode = true
                frame._inEditMode    = true
                -- Defensive re-anchor: if anything ever broke the
                -- SetAllPoints(frame) relationship (e.g. an old save
                -- where the chat had standalone anchors, or a stray
                -- StartMoving on the chat itself), pull every chat
                -- window in THIS container back onto this dock frame.
                -- Other containers' windows are left alone - their
                -- own onEnter callback fires for them.
                for _, idx in ipairs(WindowsInDock(id)) do
                    local win = windows[idx]
                    if win then
                        win:ClearAllPoints()
                        win:SetAllPoints(frame)
                    end
                end
                Window:ApplyAll()
                -- Force-show this container's active editbox + its
                -- backdrop so the user can see it while laying out.
                for _, idx in ipairs(WindowsInDock(id)) do
                    local win = windows[idx]
                    if win and win:IsShown() and win.editBox then
                        local wDB = WindowDB(idx)
                        local readOnly = wDB and wDB.eventGroup == "LOG"
                        if not readOnly then
                            win.editBox:Hide()
                            win.editBox:Show()
                        end
                    end
                end
            end,
            onExit = function()
                instance._inEditMode = false
                frame._inEditMode    = false
                Window:ApplyAll()
                for _, idx in ipairs(WindowsInDock(id)) do
                    local win = windows[idx]
                    if win and win.editBox then win.editBox:Hide() end
                end
            end,
        })
        instance._editModeRegistered = true
    end

    return instance
end

-- Back-compat shim. Old code calls Window:CreateDock() expecting the
-- main dock's Frame back. Returns the same Frame the factory creates.
function Window:CreateDock()
    return Window:CreateDockInstance("dock").frame
end

-- Look up an existing dock instance by id. Returns nil if not yet
-- created (callers that need the instance unconditionally should call
-- CreateDockInstance instead).
function Window:GetDockInstance(id)
    return Window.docks[id or "dock"]
end

-- Tear down a popped dock instance (must not be the main "dock").
-- Unregisters from Edit Mode, hides the frame, drops the entry from
-- Window.docks. Profile.docks[id] is left intact so a future re-pop
-- restores the same geometry; pass clearProfile=true to also wipe
-- the saved geometry.
function Window:DestroyDockInstance(id, clearProfile)
    if id == "dock" then return false end
    local inst = Window.docks[id]
    if not inst then return false end
    if inst._editModeRegistered and BazCore.UnregisterEditModeFrame then
        BazCore:UnregisterEditModeFrame(inst.frame)
        inst._editModeRegistered = false
    end
    if inst.tabSystem then inst.tabSystem:Hide() end
    if inst.addBtn    then inst.addBtn:Hide()    end
    inst.frame:Hide()
    inst.frame:ClearAllPoints()
    Window.docks[id] = nil
    if clearProfile then
        local p = GetProfile()
        if p and p.docks then p.docks[id] = nil end
    end
    return true
end

---------------------------------------------------------------------------
-- Mixin field initialization
---------------------------------------------------------------------------

local function InitMixinFields(f, id, label)
    f.channelList               = {}
    f.zoneChannelList           = {}
    f.messageTypeList           = {}
    f.privateMessageList        = nil
    f.excludePrivateMessageList = nil
    f.defaultLanguage           = GetDefaultLanguage and GetDefaultLanguage() or "Common"
    f.alternativeDefaultLanguage = GetAlternativeDefaultLanguage and GetAlternativeDefaultLanguage() or nil
    f.chatType                  = "SAY"
    f.name                      = label or ("Tab" .. id)  -- used by formatter for tab labels
    f:SetID(10 + id)
end

---------------------------------------------------------------------------
-- Tab construction lives in Replica/Tabs.lua.
-- Window:Create calls addon.Tabs:AddFor(f, index, label) to add the tab.
-- The dock zone-watcher calls addon.Tabs:UpdateVisibility() on zone change.
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Scrollbar + tab fade helpers will live in Replica/AutoHide.lua
-- (next refactor step). For now ApplySettings just toggles the
-- scrollbar/tab strip visibility based on whether mode == "never".
---------------------------------------------------------------------------
-- Hyperlink + mouse wheel scripts (script-side wiring; mixin provides
-- the methods themselves).
---------------------------------------------------------------------------

local function HookHyperlinks(f)
    f:SetHyperlinksEnabled(true)
    f:SetScript("OnHyperlinkClick", f.OnHyperlinkClick)
    f:SetScript("OnHyperlinkEnter", function(self, link)
        ShowUIPanel(GameTooltip)
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:SetHyperlink(link)
        GameTooltip:Show()
    end)
    f:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
end

-- Show the scroll-to-bottom button when the frame has scrolled up
-- away from its newest line; hide it when we're back at the bottom.
-- Matches default Blizzard chat behavior: the double-down arrow
-- only appears when there's something below the current view.
local function UpdateScrollToBottomButton(f)
    local btn = f.ScrollToBottomButton
    if not btn then return end
    if f:AtBottom() then
        btn:SetAlpha(0)
        btn:EnableMouse(false)
    else
        btn:SetAlpha(1)
        btn:EnableMouse(true)
    end
end

local function HookMouseWheel(f)
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(self, delta)
        local jump = IsShiftKeyDown() and self:GetNumLinesDisplayed() or 3
        if IsControlKeyDown() then
            if delta > 0 then self:ScrollToTop() else self:ScrollToBottom() end
        elseif delta > 0 then
            for _ = 1, jump do self:ScrollUp() end
        else
            for _ = 1, jump do self:ScrollDown() end
        end
        UpdateScrollToBottomButton(self)
        if addon.AutoHide then addon.AutoHide:PingScroll(self) end
    end)
end

-- Wrap the mixin's OnEvent so channel events (CHAT_MSG_CHANNEL,
-- CHAT_MSG_CHANNEL_NOTICE, NOTICE_USER, LIST) update f.channelList
-- BEFORE the mixin's tContains(channelList, name) filter check runs.
--
-- Why: GetChannelList() returns names that may not match the event's
-- arg9 channel name (e.g. GetChannelList might give "General" while
-- the event's arg9 is "General - Zul'Aman"). Pre-populating from
-- GetChannelList alone leaves the filter checking the wrong string.
-- Inspecting the event's own arg9 sidesteps the format question:
-- whatever name the mixin is about to compare, we make sure that
-- exact string is in channelList - but only when the user has the
-- corresponding base name toggled on for this tab.
-- Per-event channel-list maintenance via Blizzard's message-filter
-- API. Filter callbacks are invoked through `securecallfunction` by
-- Blizzard's own dispatcher (see ChatFrameUtil.CreateMessageEventFilterRegistry
-- in Blizzard_ChatFrameBase/Shared/ChatFrameFilters.lua), which means
-- any taint we generate inside the filter is CONTAINED to its
-- isolated call context - it cannot leak into MessageEventHandler's
-- subsequent secure operations.
--
-- The earlier approach (SetScript("OnEvent", wrappedFn)) put OUR
-- Lua function in the dispatch call stack, which by itself was
-- enough to taint the dispatch from Blizzard's perspective - even
-- with internal securecallfunction wrapping. Filters are the right
-- primitive for "react to incoming chat events without tainting."
--
-- The filter is registered ONCE per relevant event for ALL chat
-- frames. Inside, we walk addon.Window.list and update the chat
-- frame whose ID matches the filter's chatFrame argument.
local CHANNEL_EVENTS_FOR_FILTER = {
    "CHAT_MSG_CHANNEL",
    "CHAT_MSG_CHANNEL_NOTICE",
    "CHAT_MSG_CHANNEL_NOTICE_USER",
    "CHAT_MSG_CHANNEL_LIST",
}

local function MaintainChannelList(chatFrame, _, ...)
    -- Map this chat frame back to our window index so we can find
    -- its DB block.
    local idx
    for i, win in pairs(addon.Window.list or {}) do
        if win == chatFrame then idx = i; break end
    end
    if not idx then return end

    local _, _, _, _, _, _, arg7, _, arg9 = ...
    local channelName = arg9
    if canaccessvalue and not canaccessvalue(channelName) then return end
    if type(channelName) ~= "string" or channelName == "" then return end

    local p = (addon.db and addon.db.profile)
        or (addon.core and addon.core.db and addon.core.db.profile)
    local ws = p and p.windows and p.windows[idx]
    if not ws or not ws.channels then return end

    local base = (addon.Channels and addon.Channels.ChannelBaseName)
        and addon.Channels.ChannelBaseName(channelName) or nil
    local toggled = (base and ws.channels["channel:" .. base])
        or ws.channels.channel
    if not toggled then return end

    chatFrame.channelList     = chatFrame.channelList     or {}
    chatFrame.zoneChannelList = chatFrame.zoneChannelList or {}
    for _, n in ipairs(chatFrame.channelList) do
        if n == channelName then return end
    end
    chatFrame.channelList[#chatFrame.channelList + 1]     = channelName
    chatFrame.zoneChannelList[#chatFrame.zoneChannelList + 1] =
        (arg7 and arg7 > 0) and arg7 or false
end

local function InstallChannelListFilter()
    if Window._channelListFilterInstalled then return end
    Window._channelListFilterInstalled = true
    local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter)
        or _G.ChatFrame_AddMessageEventFilter
    if not addFilter then return end
    for _, evt in ipairs(CHANNEL_EVENTS_FOR_FILTER) do
        addFilter(evt, MaintainChannelList)
    end
end

-- Wrap AddMessage so:
--   1. UpdateScrollToBottomButton runs after every new line (so the
--      double-down jump-to-bottom button appears when scrolled up).
--   2. addon.Persistence captures the line for replay across /reload.
-- Done as a method override (not hooksecurefunc) since AddMessage is
-- a frame method, not a global function.
--
-- We stash the ORIGINAL AddMessage on f._bcOriginalAddMessage so the
-- Persistence module can replay history without re-routing through
-- our hook (otherwise the replayed lines would get re-appended to
-- history every reload, doubling forever).
-- Probe a string for "secret" status. WoW marks certain chat strings
-- (encounter warnings, cross-realm names in some contexts, GM whispers,
-- etc.) so that comparison / concatenation / format operations on them
-- error with "attempt to compare ... a secret string value, while
-- execution tainted by 'BazChat'". We pcall a comparison-with-empty-
-- string probe; if it errors, the string is secret and we MUST NOT
-- run any of our normal text processing on it - any such op would
-- propagate the taint into Blizzard's downstream secure code.
local function IsSafeText(s)
    if type(s) ~= "string" then return false end
    local ok = pcall(function() return s == "" end)
    return ok
end

local function HookAddMessage(f, idx)
    local original = f.AddMessage
    if type(original) ~= "function" then return end
    f._bcOriginalAddMessage = original
    f.AddMessage = function(self, text, r, g, b, messageId, holdTime, ...)
        -- Secret-string bypass: if the engine has marked this text as
        -- protected (encounter warnings, restricted whispers, etc.),
        -- skip ALL of our processing - rewrite, sentinel injection,
        -- and persistence - and just pass the message straight to the
        -- SMF's original AddMessage. The user still sees the line; we
        -- just don't try to mutate or store it.
        if not IsSafeText(text) then
            original(self, text, r, g, b, messageId, holdTime, ...)
            UpdateScrollToBottomButton(self)
            return
        end

        -- Display-time text rewrite: shorten bracketed channel
        -- prefixes ([Guild] -> [g], [1. General - X] -> [General]).
        -- Persistence stores the RAW text (below) so toggling the
        -- feature off later doesn't fossilize old shortenings; replay
        -- re-applies the rewrite on the way back into the chat.
        local rendered = text
        if addon.ChannelNames and addon.ChannelNames.Rewrite then
            rendered = addon.ChannelNames:Rewrite(text)
        end

        -- Two-column timestamps: the SMF body is shifted past the
        -- timestamp gutter by Replica/TimestampOverlay's RefreshLayout
        -- hook, so we DON'T pad the text - the body's natural left
        -- edge already sits where it should. We only inject the unix
        -- time as a sentinel-paired extra so the overlay system can
        -- read it back per-line without polluting visible text.

        -- If a caller already injected a timestamp via the sentinel
        -- (e.g. Persistence:Replay passing the original capture time),
        -- preserve it. Otherwise append our own current-time pair.
        local hasSentinel = false
        if addon.Timestamps and select("#", ...) > 0 then
            local n = select("#", ...)
            for i = 1, n - 1 do
                if select(i, ...) == addon.Timestamps.SENTINEL then
                    hasSentinel = true
                    break
                end
            end
        end

        if hasSentinel or not addon.Timestamps then
            original(self, rendered, r, g, b, messageId, holdTime, ...)
        else
            original(self, rendered, r, g, b, messageId, holdTime, ...,
                addon.Timestamps.SENTINEL, time())
        end

        UpdateScrollToBottomButton(self)
        if addon.Persistence then
            -- Persist RAW text (pre-rewrite) so disabling the feature
            -- in a later session doesn't leave shortened brackets in
            -- the visible history.
            addon.Persistence:Append(idx, text, r, g, b)
        end
    end
end

---------------------------------------------------------------------------
-- Public: Window:Create
---------------------------------------------------------------------------

function Window:Create(index, opts)
    opts = opts or {}
    if windows[index] then return windows[index] end

    local globalName = "BazChatWindow" .. index
    local ws         = WindowDB(index)
    local label      = opts.label or ws.label or "General"

    -- Use our XML template for the visual chrome + edit box + buttons.
    local f = CreateFrame("ScrollingMessageFrame", globalName, UIParent, "BazChatFrameTemplate")

    -- Anchor every chat window to its container's dock root via
    -- SetAllPoints. The container (main "dock" or a "pop:<n>" instance)
    -- owns position + size; chat windows just sit inside it. Edit Mode
    -- drags the container, so all windows + tabs in that container move
    -- together rigidly with no teleport / snap-back artifacts.
    local dockID    = (ws and ws.dockID) or "dock"
    local container = Window:CreateDockInstance(dockID).frame
    f:ClearAllPoints()
    f:SetAllPoints(container)
    f._dockID = dockID
    -- Only the first window is shown by default; the rest start hidden
    -- and the tab callback swaps them in. NB: ChatFrameEditBoxTemplate
    -- reparents itself to UIParent in its OnLoad, so hiding the chat
    -- frame does NOT cascade to its editBox - we have to hide that
    -- separately or every window's editBox renders simultaneously
    -- (overlapping "[Guild][Trade - City]:" headers).
    if index == 1 then
        f:Show()
    else
        f:Hide()
    end

    -- Replace the inherited FloatingBorderedFrame chrome with the
    -- modern dark-gold housing-dashboard NineSlice. ApplyDefault
    -- hides the inherited template textures; Apply adds a sibling
    -- NineSlice wrapper frame anchored to the chat's bounds with a
    -- lower frame level so chat text renders on top. Both live in
    -- Replica/Chrome.lua.
    if addon.Chrome then
        addon.Chrome:ApplyDefault(f)
        addon.Chrome:Apply(f)
    end

    -- Text padding: the FontStringContainer reanchor approach was
    -- pushing text outside the chat's visible bottom (FontStringContainer
    -- isn't actually the rendering target on a basic ScrollingMessageFrame).
    -- We'll handle padding in Phase 3.5 by wrapping the SMF in a chrome
    -- frame so the visible backdrop and the text rect can have different
    -- bounds. For now text renders at its default position.

    -- Edit box. Always-on for chat tabs (Chatinator / Prat-style),
    -- HIDDEN for the Log tab - that tab is a read-only event log,
    -- matching default Blizzard ChatFrame2 which has no input.
    local groupKey = opts.eventGroup or ws.eventGroup or "GENERAL"
    if f.editBox then
        if groupKey == "LOG" then
            f.editBox:Hide()
            f.editBox:EnableMouse(false)
        else
            -- Editbox is hidden by default — appears only when the
            -- user activates chat (Enter, /, click on chat). The
            -- backdrop texture is a child of the editbox so it
            -- inherits the same hidden/shown state automatically.
            f.editBox:Hide()
            f.editBox:SetAlpha(1)
            f.editBox:EnableMouse(true)
            f.editBox:SetFrameLevel((f:GetFrameLevel() or 5) + 30)
            -- Arrow-key consumption: the ChatFrameEditBoxTemplate has
            -- ignoreArrows="true" set in XML, which defaults its
            -- AltArrowKeyMode to true - meaning up/down arrows
            -- propagate to the game (so they fire the move-forward /
            -- move-back keybinds even while typing). Force it false
            -- so the editbox consumes arrows and routes them to its
            -- native history navigation (populated by Replica/History
            -- via AddHistoryLine).
            if f.editBox.SetAltArrowKeyMode then
                f.editBox:SetAltArrowKeyMode(false)
            end
            -- Re-anchor below the chat with more clearance. The XML
            -- default is y=-4, but NineSlice chromes (Runeforge,
            -- PortraitFrame, etc.) bleed their BottomEdge / corners
            -- below the chat frame's bounds and cover the edit box at
            -- 4px gap. 20px clears every layout we've tested.
            f.editBox:ClearAllPoints()
            f.editBox:SetPoint("TOPLEFT",  f, "BOTTOMLEFT",   -7, 3)
            f.editBox:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT",  25, 3)
            f.editBox:SetHeight(50)
            -- Override editBox.chatFrame with the actual chat window.
            -- The XML's OnLoad-append sets it to self:GetParent(),
            -- which is UIParent (because ChatFrameEditBoxTemplate's
            -- own OnLoad reparents the editbox to UIParent before our
            -- append runs). Blizzard's ChatEdit_ActivateChat re-anchors
            -- the editbox based on chatFrame; if chatFrame is UIParent,
            -- the editbox lands at UIParent's BOTTOMLEFT (which happens
            -- to coincide with the dock's default position - that's
            -- why this never broke until pop-out moved the chat away
            -- from the bottom-left). Setting chatFrame = f keeps the
            -- editbox following its actual chat window in any container.
            f.editBox.chatFrame = f
            -- Translucent dark backdrop INSIDE the editbox's visible
            -- border. Tied to FOCUS state, not just shown state -
            -- ChatEdit_DeactivateChat in modern WoW fades the editbox
            -- without calling Hide(), so OnShow/OnHide alone leaves
            -- the backdrop persistently visible after the editbox
            -- "closes". Hooking focus events handles that case.
            if not f.editBox._bcBg then
                local ebg = f.editBox:CreateTexture(nil, "BACKGROUND")
                ebg:SetPoint("TOPLEFT",     f.editBox, "TOPLEFT",      9, -18)
                ebg:SetPoint("BOTTOMRIGHT", f.editBox, "BOTTOMRIGHT",  -9,  17)
                ebg:SetColorTexture(0, 0, 0, 0.6)
                ebg:SetIgnoreParentAlpha(true)   -- our alpha, not editbox's
                f.editBox._bcBg = ebg

                local function syncBg(self)
                    if not self._bcBg then return end
                    -- Show the backdrop whenever the editbox is the
                    -- active focus target OR Edit Mode is active
                    -- (visual indicator while user is laying out).
                    local inEdit = Window.dock and Window.dock._inEditMode
                    local visible = self:IsShown()
                        and (self:HasFocus() or ACTIVE_CHAT_EDIT_BOX == self or inEdit)
                    self._bcBg:SetShown(visible)
                end
                f.editBox:HookScript("OnShow", function(self)
                    HideEditBoxChrome(self)
                    syncBg(self)
                    -- Defensive re-anchor on every show. Blizzard's
                    -- ChatEdit_ActivateChat (or anything else that
                    -- shows a chat editbox) may override our anchors
                    -- with internal logic that targets ChatFrame1 or
                    -- a fixed screen position. Re-asserting them in
                    -- OnShow forces the editbox below its actual chat
                    -- window regardless of what triggered the show.
                    local cf = self.chatFrame
                    if cf and cf ~= _G.UIParent and cf.GetName then
                        self:ClearAllPoints()
                        self:SetPoint("TOPLEFT",  cf, "BOTTOMLEFT",   -7, 3)
                        self:SetPoint("TOPRIGHT", cf, "BOTTOMRIGHT",  25, 3)
                    end
                end)
                -- OnHide: sync the backdrop, AND if Edit Mode is
                -- active re-show on the next frame. ChatEdit_Deactivate
                -- (and a few other Blizzard code paths) hide the
                -- editbox whenever focus is lost - which during Edit
                -- Mode happens any time the user clicks the dock,
                -- a resize handle, or a settings widget. Without this
                -- hook the editbox flickers off mid-layout. We defer
                -- the re-show by one frame so Blizzard's Hide path
                -- finishes cleanly first.
                f.editBox:HookScript("OnHide", function(self)
                    syncBg(self)
                    local inEdit = Window.dock and Window.dock._inEditMode
                    if inEdit and f:IsShown() and groupKey ~= "LOG" then
                        C_Timer.After(0, function()
                            if Window.dock and Window.dock._inEditMode
                               and f:IsShown() and not self:IsShown() then
                                self:Show()
                            end
                        end)
                    end
                end)
                f.editBox:HookScript("OnEditFocusGained", syncBg)
                f.editBox:HookScript("OnEditFocusLost",   syncBg)
                syncBg(f.editBox)
            end
            -- Hide the bordered chrome on the input bar (Left/Mid/Right
            -- + focus variants) per user preference - the typed text
            -- + cursor is enough.
            HideEditBoxChrome(f.editBox)
            -- Set default chat type for THIS tab's edit box. Drives
            -- both the visible "Say:" / "Guild:" / "[2. Trade]:"
            -- header AND where Enter sends the message.
            if addon.Tabs then addon.Tabs:ApplyChatType(f.editBox, groupKey) end
            -- Populate in-session up-arrow / down-arrow history from
            -- the persistent saved list (Replica/History.lua).
            if addon.History then addon.History:Apply(f.editBox) end
        end
    end

    -- Layer Blizzard's chat formatter onto the frame. Defensive guard
    -- in case a future patch ever moves ChatFrameMixin: the frame
    -- still works, just without formatting.
    if type(ChatFrameMixin) == "table" and type(ChatFrameMixin.MessageEventHandler) == "function" then
        Mixin(f, ChatFrameMixin)
    elseif addon.core then
        addon.core:Print("|cffff4444ChatFrameMixin missing; chat will not format.|r")
    end
    InitMixinFields(f, index, label)

    -- Static behavior. The dynamic per-window settings (alpha, scale,
    -- fade, scrollbar, fading, etc) all live in the DB and get applied
    -- below via Window:ApplySettings(). That way the Settings page and
    -- Edit Mode popup can both call ApplySettings to re-render live.
    f:SetFontObject(_G[opts.fontObject or FALLBACKS.fontObject])
    f:SetJustifyH("LEFT")
    -- DO NOT SetClipsChildren(true) here. The TabSystem is parented to
    -- this frame (so it follows the chat as it moves) but anchored above
    -- the chat's top edge - i.e. outside the chat's clip rect. Clipping
    -- children would hide the tab entirely. ScrollingMessageFrame already
    -- clips its own message rendering, so we don't need clip-children
    -- for the chat text either.

    -- Position is owned by the DOCK. The chat window is SetAllPoints
    -- to the dock so it follows automatically. Do NOT make the chat
    -- frame itself movable / drag-sourced - StartMoving on f would
    -- give it standalone anchors and break the SetAllPoints
    -- relationship, after which dragging the dock (in Edit Mode)
    -- moves the highlight + tabs but leaves the chat behind. EnableMouse
    -- is still on so clicks land on chat (clickAnywhereButton, hyperlinks,
    -- mouse-wheel scroll all need it).
    f:EnableMouse(true)

    -- Click anywhere in the chat -> focus edit box. Now that the edit
    -- box exists (via the XML template), enable the helper button.
    if f.clickAnywhereButton then
        f.clickAnywhereButton:Show()
    end

    -- Wire mixin methods to actual scripts. OnEvent goes DIRECTLY to
    -- the mixin method - we don't wrap it with addon Lua code because
    -- doing so put OUR closure in the call stack, which the engine
    -- treats as taint and contaminates Blizzard's downstream secure
    -- operations (RemoveExtraSpaces, ChatHistory_GetAccessID, etc.).
    -- Channel-list maintenance now happens via a registered message
    -- filter (Blizzard wraps those in securecallfunction) - see
    -- InstallChannelListFilter below, called once per session.
    f:SetScript("OnEvent", f.OnEvent)
    InstallChannelListFilter()
    HookHyperlinks(f)
    HookMouseWheel(f)
    HookAddMessage(f, index)
    -- Two-column timestamp overlay system. Hooks the SMF's
    -- RefreshDisplay so per-message timestamps render as labels
    -- anchored to each visibleLine - keeps wrap geometry clean
    -- because the timestamp isn't in the message body.
    if addon.TimestampOverlay then
        addon.TimestampOverlay:Wire(f)
    end

    -- Re-anchor the ScrollBar so it ends 18px above the chat's bottom
    -- edge. That leaves a slot at the bottom-right for the
    -- ScrollToBottomButton without overlapping the ScrollBar's own
    -- down-arrow. (The XML's default was full-height TOPRIGHT to
    -- BOTTOMRIGHT, which collided with ScrollToBottomButton.)
    if f.ScrollBar then
        f.ScrollBar:ClearAllPoints()
        -- Anchor to the CHROME wrapper (sibling frame outset 10/11/29
        -- pixels from the chat) instead of the chat itself, so the
        -- scrollbar sits flush against the visible gold border on the
        -- right edge rather than being inset by the chrome's padding.
        -- Falls back to the chat frame if chrome hasn't been built.
        local anchor = f._bcChromeFrame or f
        -- TOPRIGHT y = -28 leaves room above the scrollbar for the
        -- copy-chat icon (anchored at TOPRIGHT -8,-8 with 14px size,
        -- so bottom edge sits at y=-22; the extra 6px is the gap).
        f.ScrollBar:SetPoint("TOPRIGHT",    anchor, "TOPRIGHT",    -10, -28)
        f.ScrollBar:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -10,  55)
    end

    -- Bind the MinimalScrollBar to the ScrollingMessageFrame using
    -- Blizzard's own ScrollUtil helper (this is what default ChatFrame
    -- does in modern WoW). Handles thumb-tracking-on-scroll AND the
    -- inverse: dragging the thumb scrolls the SMF. Last arg = true
    -- means "skip mouse wheel registration" since we wire our own
    -- (HookMouseWheel above) for shift/ctrl modifier behavior.
    if f.ScrollBar and ScrollUtil and ScrollUtil.InitScrollingMessageFrameWithScrollBar then
        ScrollUtil.InitScrollingMessageFrameWithScrollBar(f, f.ScrollBar, true)
    end

    -- Wire scrollbar + tab-strip hover hooks for the auto-hide modes.
    -- Lives in Replica/AutoHide.lua. Hooks ONLY clickAnywhereButton
    -- and the ScrollBar - never the SMF (see AutoHide docstring for
    -- why; it caused the v143-v149 breakage).
    if addon.AutoHide then addon.AutoHide:WireWindow(f) end

    -- Tiny copy-chat icon at the chrome's top-right corner. Click to
    -- pop BazCore:OpenCopyDialog with this tab's lines pre-selected
    -- for Ctrl+A / Ctrl+C - WoW chat isn't natively selectable.
    if addon.CopyChat then addon.CopyChat:Wire(f) end

    -- Re-anchor the ScrollToBottomButton centered horizontally with
    -- the ScrollBar (anchoring both to chat's BOTTOMRIGHT misaligns
    -- them because the two button textures have different widths).
    -- TOP-of-SBB to BOTTOM-of-ScrollBar so they stack cleanly with
    -- the SBB's center on the ScrollBar's center line.
    if f.ScrollToBottomButton and f.ScrollBar then
        f.ScrollToBottomButton:ClearAllPoints()
        f.ScrollToBottomButton:SetPoint("TOP", f.ScrollBar, "BOTTOM", 0, -2)
        f.ScrollToBottomButton:SetFrameLevel((f:GetFrameLevel() or 5) + 10)
    end
    UpdateScrollToBottomButton(f)

    -- Re-anchor + re-wire the ResizeButton. The XML has it driving
    -- chat-frame resize, but our chat windows are SetAllPoints to
    -- their container - resizing the chat directly would override
    -- that anchor. Redirect drag to the container (the chat's dock
    -- instance frame) so resize moves the whole assembly. The
    -- container is resolved per-event so PopOut/PopIn re-routing
    -- "just works" without rebinding the button on every migration.
    if f.ResizeButton and f._bcChromeFrame then
        f.ResizeButton:ClearAllPoints()
        f.ResizeButton:SetPoint("BOTTOMRIGHT", f._bcChromeFrame,
            "BOTTOMRIGHT", -2, 22)
        f.ResizeButton:SetFrameLevel((f:GetFrameLevel() or 5) + 10)
        local function ContainerOf()
            local inst = Window.docks[f._dockID or "dock"]
            return inst and inst.frame or Window.dock
        end
        f.ResizeButton:SetScript("OnMouseDown", function(self)
            self:SetButtonState("PUSHED", true)
            local hl = self:GetHighlightTexture()
            if hl then hl:Hide() end
            local c = ContainerOf()
            if c then c:StartSizing("BOTTOMRIGHT") end
        end)
        f.ResizeButton:SetScript("OnMouseUp", function(self)
            self:SetButtonState("NORMAL", false)
            local hl = self:GetHighlightTexture()
            if hl then hl:Show() end
            local c = ContainerOf()
            if c then c:StopMovingOrSizing() end
        end)
    end

    -- Replay persisted chat history into the frame BEFORE we subscribe
    -- to live events, so the historic lines render above any incoming
    -- messages chronologically. Persistence uses the captured original
    -- AddMessage so replayed lines don't get re-stored back into history.
    if addon.Persistence then
        addon.Persistence:Replay(f, index)
    end

    -- Subscribe to chat events for this window. A window only
    -- receives events it's registered for, so the Guild tab shows only
    -- guild traffic without per-event filtering. The channel set lives
    -- in windows[idx].channels (see Replica/Channels.lua) and is kept
    -- in sync with the right-click popup + the Tabs options page.
    if addon.Channels then
        addon.Channels:Subscribe(f, index)
        -- Manual Guild MOTD recovery on the primary window only. The
        -- actual GUILD_MOTD event fired before we registered for it
        -- (during cold login while guild data was still loading), so
        -- we fetch the cached value from C_GuildInfo.GetMOTD() and
        -- AddMessage it to window 1. Restricting to window 1 keeps the
        -- MOTD from showing up multiple times for users who split
        -- Guild chat to its own tab; window 1 is the user's primary
        -- view either way. Live MOTD changes during the session still
        -- come through the registered GUILD_MOTD event normally.
        local wsBlock = WindowDB(index)
        if index == 1 and wsBlock and addon.Channels.DisplayInitialMOTD then
            addon.Channels:DisplayInitialMOTD(f, wsBlock)
        end
    end

    -- Modern tab above the window. addon.Tabs:AddFor lazily creates
    -- the shared TabSystem on the first call and adds one tab per call.
    if addon.Tabs then
        tabs[index] = addon.Tabs:AddFor(f, index, label)
    end

    windows[index] = f

    -- Apply the live, DB-bound settings (alpha, scale, fade, etc.)
    -- AFTER the window is in `windows[]` so ApplySettings can find it.
    Window:ApplySettings(index)

    -- Claim Blizzard's chat-system globals for window 1. Without this:
    --   * Pressing Enter (OPENCHAT keybind) opens ChatFrame1's edit
    --     box because ChatFrame_OpenChat() reads DEFAULT_CHAT_FRAME
    --     and we leave that pointing at ChatFrame1.
    --   * /script print() and most addon prints go to ChatFrame1
    --     because they call DEFAULT_CHAT_FRAME:AddMessage.
    --   * Any code that does `DEFAULT_CHAT_FRAME:Show()` (and there
    --     is some, especially for stuck-popup / error reporting)
    --     re-shows ChatFrame1 even though we hid it - that's why the
    --     default chat keeps coming back.
    -- Pointing these at our window 1 routes all of that through our
    -- replica instead. Window 2+ stay subscribers only.
    if index == 1 then
        DEFAULT_CHAT_FRAME  = f
        SELECTED_CHAT_FRAME = f
        SELECTED_DOCK_FRAME = f   -- ChatEdit_ChooseBoxForSend prefers this
        if f.editBox then
            -- Make our editbox the canonical "last active" so pressing
            -- Enter immediately after /reload targets it. Without
            -- this, ChatEdit_ChooseBoxForSend may return a stale
            -- ACTIVE_CHAT_EDIT_BOX (e.g. ChatFrame1's hidden box from
            -- Blizzard's own init) and Enter does nothing visible.
            -- Setting both globals + calling
            -- ChatEdit_SetLastActiveWindow (if it still exists) keeps
            -- us robust across patches.
            LAST_ACTIVE_CHAT_EDIT_BOX = f.editBox
            if ACTIVE_CHAT_EDIT_BOX and ACTIVE_CHAT_EDIT_BOX ~= f.editBox then
                ACTIVE_CHAT_EDIT_BOX = nil
            end
            if ChatEdit_SetLastActiveWindow then
                ChatEdit_SetLastActiveWindow(f.editBox)
            end
        end
    end

    -- Edit Mode is registered on the DOCK only (in Window:CreateDock),
    -- not per-window. Dragging the dock moves the whole chat dock
    -- (windows + tabs) rigidly via the SetAllPoints anchoring above.
    -- Per-window settings live in the BazChat-Settings page.
    f:SetMovable(false)
    f:RegisterForDrag()
    f:SetScript("OnDragStart", nil)
    f:SetScript("OnDragStop", nil)

    return f
end

---------------------------------------------------------------------------
-- Live settings application
--
-- ApplySettings reads the per-window block from the DB and re-applies
-- everything that can be changed at runtime to the live frame. Both the
-- Settings page and the Edit Mode popup call this on every setter so
-- changes are visible immediately - no /reload, no widget refresh
-- gymnastics. Position + size are NOT re-applied here (those are owned
-- by Edit Mode's drag handlers and the resize grabber respectively).
---------------------------------------------------------------------------

function Window:ApplySettings(idx)
    local f = windows[idx]
    if not f then return end
    -- Chrome settings (alpha/scale/scrollbar/fading/etc.) are SHARED
    -- across every chat window in the dock. The Edit Mode popup and
    -- the Settings page both write to windows[1] only, so we treat
    -- windows[1] as the canonical chrome block. Per-window fields
    -- (label, eventGroup) still come from windows[idx].
    local chrome  = WindowDB(1) or WindowDB(idx)
    local inEdit  = Window.dock and Window.dock._inEditMode
    local locked  = not inEdit

    -- Appearance
    -- alpha   = chat text + scrollbar (children of f) opacity
    -- bgAlpha = NineSlice chrome panel opacity (independent sibling)
    f:SetAlpha(chrome.alpha or FALLBACKS.alpha)
    if addon.Chrome then
        addon.Chrome:SetAlpha(f, chrome.bgAlpha or FALLBACKS.bgAlpha)
    end
    f:SetScale(chrome.scale or FALLBACKS.scale)

    -- Scrollbar + tab-strip visibility (mode-aware fade) live in
    -- Replica/AutoHide.lua. inEdit forces them visible regardless.
    if addon.AutoHide then addon.AutoHide:Apply(f, inEdit) end

    -- Lock state: resize handle visible only when dock is in Edit Mode.
    if f.SetResizable then f:SetResizable(not locked) end
    if f.ResizeButton then f.ResizeButton:SetShown(not locked) end

    -- Scrollbar height tracks lock state: leave room for the resize
    -- grabber when unlocked (55 inset), extend further down when locked
    -- (45 inset). Top inset = 28 keeps the scrollbar below the
    -- copy-chat icon (icon at -8,-8 size 14 -> bottom at y=-22, +6 gap).
    if f.ScrollBar then
        local anchor = f._bcChromeFrame or f
        f.ScrollBar:ClearAllPoints()
        f.ScrollBar:SetPoint("TOPRIGHT",    anchor, "TOPRIGHT",    -10, -28)
        f.ScrollBar:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -10,
            locked and 45 or 55)
    end

    -- Behavior (canonical)
    f:SetMaxLines(chrome.maxLines or FALLBACKS.maxLines)
    f:SetFading(chrome.fading ~= false)
    f:SetFadeDuration(chrome.fadeDuration or FALLBACKS.fadeDuration)
    f:SetTimeVisible(chrome.timeVisible or FALLBACKS.timeVisible)
    -- IndentedWordWrap: when timestamps are active, the gutter shift
    -- in TimestampOverlay handles continuation alignment cleanly via
    -- the FontString's anchor; the native indent would push wraps an
    -- extra word in past the body's left edge ("too indented" look).
    -- Force false in that case; otherwise honor the user's setting.
    local p = (addon.db and addon.db.profile)
        or (addon.core and addon.core.db and addon.core.db.profile)
    local tsOn = p and p.timestamps and p.timestamps.enabled
    if tsOn then
        f:SetIndentedWordWrap(false)
    else
        f:SetIndentedWordWrap(chrome.indentedWordWrap ~= false)
    end
    -- Inter-line pixel spacing. SMF's native :SetSpacing applies to
    -- all visible row boundaries, including wrapped continuations of
    -- a single AddMessage call - so a small value (2-4 px) reads as
    -- "subtle gap between everything" while a larger value gets
    -- noticeable for both message gaps AND wraps. Trade-off: this is
    -- the only spacing primitive SMF exposes; the alternative
    -- (inserting blank rows between messages) burns a full font line
    -- per spacer which is too much. SetSpacing wins for finer control.
    if f.SetSpacing then
        f:SetSpacing(chrome.messageSpacing or 0)
    end
end

function Window:ApplyAll()
    for idx in pairs(windows) do
        Window:ApplySettings(idx)
    end
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- The canonical set of windows we expect to materialize on each
-- /reload. Used as a migration safety net: if a saved BazChatDB is
-- missing a default window (e.g. saved before windows[2] / Guild
-- existed), we copy the canonical entry into the DB before iterating.
-- BazCore's defaults merge usually does this, but we've seen edge
-- cases with already-populated profiles where new defaults aren't
-- deep-merged in - this guarantees all canonical tabs always show up.
local CANONICAL_WINDOWS = {
    [1] = { label = "General", eventGroup = "GENERAL", autoShow = "always" },
    [2] = { label = "Guild",   eventGroup = "GUILD",   autoShow = "always" },
    [3] = { label = "Trade",   eventGroup = "LOOT",    autoShow = "city"   },
    [4] = { label = "Log",     eventGroup = "LOG",     autoShow = "always" },
}
-- Expose to other modules (used by addon.Tabs:ResetTabsToDefaults).
Window.CANONICAL_WINDOWS = CANONICAL_WINDOWS

-- Per-window default chrome / behavior values used when migrating a
-- canonical window into a saved DB that doesn't have it yet. Mirrors
-- the values in DEFAULTS.windows[*] in Core/Init.lua.
local CANONICAL_WINDOW_DEFAULTS = {
    -- Container the tab lives in. New canonical tabs always start
    -- docked; user can pop them out later.
    dockID           = "dock",
    -- Legacy geometry fields, kept so the multi-dock migration can
    -- read pre-upgrade values out of windows[1]. New canonicals don't
    -- use these for layout - their container's docks[dockID] entry is
    -- the source of truth.
    pos              = nil,
    width            = 440,
    height           = 120,
    -- locked removed in v072: lock state now tracks Edit Mode rather
    -- than being a saved per-window setting.
    alpha            = 1.0,
    bgAlpha          = 0.75,
    bgMode           = "always",
    tabsAlpha        = 1.0,
    chromeFadeMode   = "always",
    scale            = 1.0,
    showScrollbar    = true,
    fading           = true,
    fadeDuration     = 0.5,
    timeVisible      = 120,
    maxLines         = 500,
    indentedWordWrap = true,
    messageSpacing   = 3,
}

---------------------------------------------------------------------------
-- One-shot profile migration: pre-multi-dock saves stored dock geometry
-- (pos/width/height) on windows[1] and used a windows[idx].popped boolean
-- + windows[idx].popPos block for popped tabs. Multi-dock moves all
-- container geometry into profile.docks[id] and tags each tab with
-- windows[idx].dockID so the same code path handles main + popped docks.
--
-- Idempotent. Runs every CreateAll but skips fields that already exist,
-- so /reload doesn't disturb the post-migration state.
---------------------------------------------------------------------------

local function MigrateProfileForMultiDock(p)
    if not p then return end
    if p._multiDockMigrated then return end   -- one-shot
    p.windows = p.windows or {}
    p.docks   = p.docks   or {}

    -- 1. Seed the canonical "dock" entry from windows[1] geometry.
    -- BazCore's profile-defaults merge has already filled p.docks.dock
    -- with default values (440 / 120 / nil pos), so we MUST overwrite
    -- when windows[1] has a user value - "if not dock.width" would
    -- always be false post-merge. The one-shot sentinel above makes
    -- this safe to do unconditionally on first load.
    local dock = p.docks.dock or {}
    p.docks.dock = dock
    local w1 = p.windows[1]
    if w1 then
        if w1.pos    then dock.pos    = CopyTable(w1.pos) end
        if w1.width  then dock.width  = w1.width          end
        if w1.height then dock.height = w1.height         end
        -- Clear the legacy fields. Subsequent loads see the data only
        -- in docks.dock; the BazCore defaults merge would refill these
        -- with the legacy defaults, but the migration sentinel keeps
        -- us from copying back. The two values eventually drift and
        -- only docks.dock is read by anything live.
        w1.pos    = nil
        w1.width  = nil
        w1.height = nil
    end
    if not dock.width  then dock.width  = FALLBACKS.width  end
    if not dock.height then dock.height = FALLBACKS.height end

    -- 2. Migrate popped tabs into their own dock instances. The legacy
    -- popped/popPos fields are cleared after migration so the new
    -- code path is the only one reading container state.
    for idx, ws in pairs(p.windows) do
        if ws.popped and not ws.dockID then
            local id = "pop:" .. tostring(idx)
            -- Make sure we don't collide with an existing dock id (eg
            -- from a partially-migrated save).
            local n = 1
            while p.docks[id] do
                n = n + 1
                id = "pop:" .. tostring(idx) .. "_" .. tostring(n)
            end
            local pp = ws.popPos or {}
            p.docks[id] = {
                pos = (pp.point and {
                    point    = pp.point,
                    relPoint = pp.relativePoint,
                    x        = pp.x or 0,
                    y        = pp.y or 0,
                }) or nil,
                width  = pp.w or FALLBACKS.width,
                height = pp.h or FALLBACKS.height,
            }
            ws.dockID = id
            ws.popped = nil
            ws.popPos = nil
        end
    end

    -- 3. Default every other tab to the main dock.
    for _, ws in pairs(p.windows) do
        if not ws.dockID then ws.dockID = "dock" end
    end

    p._multiDockMigrated = true
end

-- Create all windows. Called from Replica:Start after PLAYER_LOGIN.
-- Walks CANONICAL_WINDOWS and ensures each entry exists in the DB
-- (copying defaults for any missing one) before instantiating it.
function Window:CreateAll()
    local p = GetProfile()
    if p then p.windows = p.windows or {} end

    MigrateProfileForMultiDock(p)
    Window:InstallChatRoutingHook()

    for idx, canon in ipairs(CANONICAL_WINDOWS) do
        -- Skip canonicals the user explicitly deleted via Tabs:DeleteTab
        -- (Guild, Trade, Log can each be removed and stay removed).
        -- General (idx 1) is undeletable, so it's never in this set.
        if p and p.deletedCanonicals and p.deletedCanonicals[idx] then
            -- intentional noop; the entry stays absent from windows[]
        else
        -- Migration: graft the canonical entry into the DB if missing,
        -- and always sync canonical label + eventGroup. Label sync
        -- handles renames across versions ("Combat Log" -> "Log" etc.).
        if p then
            if not p.windows[idx] then
                p.windows[idx] = CopyTable(CANONICAL_WINDOW_DEFAULTS)
            end
            p.windows[idx].label      = canon.label
            p.windows[idx].eventGroup = canon.eventGroup
            -- One-time channel migration: seed channels{} from the
            -- legacy eventGroup preset on first load post-upgrade.
            -- After this, channels{} is the source of truth and the
            -- eventGroup field stops being read for subscription.
            if not p.windows[idx].channels and addon.Channels then
                p.windows[idx].channels =
                    addon.Channels:DefaultsFor(canon.eventGroup or "GENERAL")
            end
            -- One-time autoShow seed: Trade tab gets "city", others
            -- "always" (per CANONICAL_WINDOWS). Only set when missing
            -- so user customizations don't get overwritten on /reload.
            if p.windows[idx].autoShow == nil then
                p.windows[idx].autoShow = canon.autoShow or "always"
            end
            -- One-time migration: legacy chromeFadeSync (boolean) ->
            -- chromeFadeMode (string). When sync was on, both bgMode
            -- and tabsMode were already mirrored, so picking either
            -- gives the right unified value.
            if p.windows[idx].chromeFadeSync ~= nil then
                if p.windows[idx].chromeFadeSync then
                    p.windows[idx].chromeFadeMode =
                        p.windows[idx].bgMode or "onhover"
                else
                    p.windows[idx].chromeFadeMode = "off"
                end
                p.windows[idx].chromeFadeSync = nil
            end
        end

        Window:Create(idx, { label = canon.label, eventGroup = canon.eventGroup })
        end  -- end if-not-deleted-canonical
    end

    -- Instantiate any user-created tabs (windows[5+]) saved from the
    -- last session. These have no canonical entry, so we read label +
    -- channels straight from their DB block. Iterates in numeric order
    -- via pairs + sort so gaps from previous deletes are tolerated.
    if p and p.windows then
        local extras = {}
        for idx in pairs(p.windows) do
            if idx > #CANONICAL_WINDOWS then extras[#extras + 1] = idx end
        end
        table.sort(extras)
        for _, idx in ipairs(extras) do
            local ws = p.windows[idx]
            Window:Create(idx, { label = ws.label or ("Tab " .. idx) })
        end
    end

    -- Apply user's saved tab order (if any). Done after every tab is
    -- in tabSystem.tabs so layoutIndex assignments resolve correctly.
    if addon.TabDrag and addon.Tabs and addon.Tabs.system then
        addon.TabDrag:LoadOrder(addon.Tabs.system)
    end

    -- Initial Guild MOTD render. Called HERE rather than from inside
    -- Window:Create because TryRenderInitialMOTD looks up windows[1]
    -- via addon.Window:Get(1), and that table isn't populated until
    -- Window:Create returns. By moving the call here we guarantee
    -- windows[1] is available when GetMOTD() is queried.
    if addon.Channels and addon.Channels.TryRenderInitialMOTD then
        addon.Channels:TryRenderInitialMOTD()
    end
end

function Window:AddMessage(windowIdx, text, r, g, b, messageId, holdTime)
    local target = windows[windowIdx or 1]
    if not target then return end
    target:AddMessage(text, r, g, b, messageId, holdTime)
end

function Window:Get(idx)  return windows[idx]  end
function Window:GetTab(idx) return tabs[idx] end

function Window:All()
    local out = {}
    for i, w in pairs(windows) do out[i] = w end
    return out
end

---------------------------------------------------------------------------
-- Active-container tracking
---------------------------------------------------------------------------
--
-- Exactly one chat container is "active" at any moment. Active means:
--   * Its tab strip visually shows the selected tab highlighted
--   * Its editbox is the target of ChatEdit_ActivateChat on tab clicks
--   * Pressing Enter / "/" while no editbox is open focuses this
--     container's editbox
--
-- The active container is identified by its dockID: "dock" for the
-- main dock, "pop:<n>" for a popped instance. Window.activeContainer
-- holds that dockID. (Pre-multi-dock this was nil-or-windowIdx; legacy
-- callers that pass nil mean "dock", and legacy callers that pass an
-- int mean "the window's container" - both are coerced.)
--
-- Inactive containers' strips visually deselect all their tabs - even
-- though their internal selectedTabID stays the same, so that when
-- they become active again the previously-selected tab re-highlights
-- without losing track.
---------------------------------------------------------------------------

Window.activeContainer = "dock"

local function VisualSelect(ts, selected)
    if not ts or not ts.tabs then return end
    if selected and ts.selectedTabID and ts.SetTabVisuallySelected then
        ts:SetTabVisuallySelected(ts.selectedTabID)
    else
        for _, tab in ipairs(ts.tabs) do
            if tab.SetTabSelected then tab:SetTabSelected(false) end
        end
    end
end

function Window:SetActiveContainer(arg)
    -- Coerce to a dockID string. nil -> "dock"; numeric idx -> the
    -- window's current dockID; string -> use as-is.
    local dockID
    if arg == nil then
        dockID = "dock"
    elseif type(arg) == "number" then
        dockID = DockIDForWindow(arg)
    else
        dockID = arg
    end

    Window.activeContainer = dockID

    -- Walk every dock instance's strip; visually select only the
    -- active container's strip.
    for id, inst in pairs(Window.docks) do
        VisualSelect(inst.tabSystem, id == dockID)
    end

    -- Route Blizzard's Enter / "/" keybinds to the active container's
    -- selected tab's frame. ChatFrame_OpenChat reads DEFAULT_CHAT_FRAME;
    -- ChatEdit_ChooseBoxForSend falls back to LAST_ACTIVE_CHAT_EDIT_BOX -
    -- pointing both at the active container makes typing routing
    -- follow focus instead of always landing on window 1.
    local inst = Window.docks[dockID]
    local s    = inst and inst.tabSystem
    local activeFrame
    if s and s.selectedTabID then
        local idx = (addon.Tabs and addon.Tabs.WindowIdxOf
                     and addon.Tabs:WindowIdxOf(s, s.selectedTabID))
                    or s.selectedTabID
        activeFrame = windows[idx]
    end
    if not activeFrame then
        -- Fallback: any visible window in the container.
        for _, idx in ipairs(WindowsInDock(dockID)) do
            if windows[idx] and windows[idx]:IsShown() then
                activeFrame = windows[idx]
                break
            end
        end
    end

    if activeFrame then
        DEFAULT_CHAT_FRAME  = activeFrame
        SELECTED_CHAT_FRAME = activeFrame
        -- SELECTED_DOCK_FRAME is what ChatEdit_ChooseBoxForSend picks
        -- BEFORE falling through to DEFAULT_CHAT_FRAME. Blizzard's
        -- chat dock initializes it to ChatFrame1 at boot; we never
        -- touched it pre-multi-dock because the dock + DEFAULT_CHAT_-
        -- FRAME both happened to coincide with ChatFrame1's position.
        -- Once a popped window is active and SELECTED_DOCK_FRAME is
        -- still ChatFrame1, pressing Enter activates ChatFrame1's
        -- editbox at the dock's location, not the popped window's.
        SELECTED_DOCK_FRAME = activeFrame
        if activeFrame.editBox then
            LAST_ACTIVE_CHAT_EDIT_BOX = activeFrame.editBox
            if ACTIVE_CHAT_EDIT_BOX and ACTIVE_CHAT_EDIT_BOX ~= activeFrame.editBox then
                ACTIVE_CHAT_EDIT_BOX = nil
            end
            if ChatEdit_SetLastActiveWindow then
                ChatEdit_SetLastActiveWindow(activeFrame.editBox)
            end
        end
    end
end

function Window:GetActiveContainer()
    return Window.activeContainer
end

-- Returns the window index of whichever tab is selected on the
-- currently active container's strip. Used by slash commands that
-- operate on "the chat tab the user is looking at right now."
-- Falls back to 1 (General) if anything's missing.
function Window:GetActiveWindowIdx()
    local id    = Window.activeContainer or "dock"
    local inst  = Window.docks[id]
    local strip = inst and inst.tabSystem
    if strip and strip.selectedTabID then
        return (addon.Tabs and addon.Tabs.WindowIdxOf
                and addon.Tabs:WindowIdxOf(strip, strip.selectedTabID))
            or strip.selectedTabID
    end
    return 1
end

---------------------------------------------------------------------------
-- Chat routing hook
--
-- Pressing Enter / "/" calls ChatFrame_OpenChat which calls
-- ChatEdit_ChooseBoxForSend(nil) to pick which editbox to activate.
-- That function has a fallback chain - ChatEdit_GetActiveWindow,
-- SELECTED_DOCK_FRAME, then DEFAULT_CHAT_FRAME - and on modern retail
-- the SELECTED_DOCK_FRAME global is no longer the source of truth
-- (Blizzard moved chat-dock state into FCFDock_GetSelectedWindow).
-- Setting all three globals in SetActiveContainer was insufficient.
--
-- We wrap ChatEdit_ChooseBoxForSend instead. When called with no
-- preferredChatFrame (the OPENCHAT keybind path), we substitute the
-- active container's editbox. Explicit calls with a chatFrame
-- argument fall through to the original so third-party addons that
-- target a specific frame keep working.
---------------------------------------------------------------------------

-- Debug counters for the chat-routing hooks. Bumped each time a hook
-- fires so /bc activeinfo can show whether they're being exercised.
Window._chatHookStats = {
    chooseBox        = 0,
    chooseBoxRouted  = 0,
    openChat         = 0,
    openChatRouted   = 0,
    activateChat     = 0,
    activateChatLast = nil,   -- name of last editBox activated
}

function Window:InstallChatRoutingHook()
    if Window._chatRoutingHookInstalled then return end
    Window._chatRoutingHookInstalled = true
    local stats = Window._chatHookStats

    -- Hook 1: ChatEdit_ChooseBoxForSend - returns the editbox to
    -- activate. Most chat code paths go through this. When called with
    -- no preferred frame (the typical ChatFrame_OpenChat path), we
    -- substitute the active container's editbox.
    if type(_G.ChatEdit_ChooseBoxForSend) == "function" then
        local original = _G.ChatEdit_ChooseBoxForSend
        _G.ChatEdit_ChooseBoxForSend = function(preferredChatFrame)
            stats.chooseBox = stats.chooseBox + 1
            if not preferredChatFrame then
                local idx = Window:GetActiveWindowIdx()
                local f   = windows[idx]
                if f and f.editBox then
                    stats.chooseBoxRouted = stats.chooseBoxRouted + 1
                    return f.editBox
                end
            end
            return original(preferredChatFrame)
        end
    end

    -- Hook 2: ChatFrame_OpenChat is what the OPENCHAT and
    -- OPENCHATSLASH bindings call directly with chatFrame=nil. Modern
    -- retail's implementation may bypass ChatEdit_ChooseBoxForSend in
    -- some code paths and use SELECTED_DOCK_FRAME / ChatFrame1
    -- directly. Rewriting the chatFrame argument before the original
    -- runs guarantees the active container's frame is what gets
    -- queried, regardless of internal fallback logic.
    if type(_G.ChatFrame_OpenChat) == "function" then
        local original = _G.ChatFrame_OpenChat
        _G.ChatFrame_OpenChat = function(text, chatFrame, desiredCursorPosition)
            stats.openChat = stats.openChat + 1
            if not chatFrame then
                local idx = Window:GetActiveWindowIdx()
                chatFrame = windows[idx]
                if chatFrame then
                    stats.openChatRouted = stats.openChatRouted + 1
                end
            end
            return original(text, chatFrame, desiredCursorPosition)
        end
    end

    -- Hook 3: REPLACE ChatEdit_ActivateChat so we can substitute the
    -- editbox argument before the original runs. Modern retail's
    -- OPENCHAT binding bypasses ChatFrame_OpenChat / ChatEdit_Choose-
    -- BoxForSend entirely - it walks CHAT_FRAMES, finds the first
    -- visible one (which is our Window1 in the dock), and calls
    -- ChatEdit_ActivateChat with that frame's editbox. Both pre-call
    -- hooks miss it, so we intercept ActivateChat itself: if it's
    -- handed one of OUR editboxes that doesn't match the active
    -- container, we swap to the active one. Third-party calls with
    -- non-BazChat editboxes pass through unchanged.
    if type(_G.ChatEdit_ActivateChat) == "function" then
        local original = _G.ChatEdit_ActivateChat
        _G.ChatEdit_ActivateChat = function(editBox)
            -- Is this one of our editboxes? If so, redirect to the
            -- active container's editbox.
            local isOurs = false
            for _, w in pairs(windows) do
                if w.editBox == editBox then isOurs = true break end
            end
            if isOurs then
                local idx = Window:GetActiveWindowIdx()
                local f   = windows[idx]
                if f and f.editBox and editBox ~= f.editBox then
                    editBox = f.editBox
                end
            end

            stats.activateChat = stats.activateChat + 1
            stats.activateChatLast = editBox
                and (editBox:GetName() or "<unnamed>")
                or "<nil>"

            local result = original(editBox)

            -- Re-anchor defensively: even after substitution, modern
            -- retail's ActivateChat may stomp our anchors with its
            -- own positioning logic. Re-assert below the chatFrame.
            local chatFrame = editBox and editBox.chatFrame
            if chatFrame and chatFrame ~= _G.UIParent and chatFrame.GetName then
                editBox:ClearAllPoints()
                editBox:SetPoint("TOPLEFT",  chatFrame, "BOTTOMLEFT",   -7, 3)
                editBox:SetPoint("TOPRIGHT", chatFrame, "BOTTOMRIGHT",  25, 3)
            end

            return result
        end
    end
end

---------------------------------------------------------------------------
-- Pop out / pop in
---------------------------------------------------------------------------
--
-- Popping a tab out of the dock migrates it into a brand-new dock
-- instance with a fresh dockID ("pop:<n>"). The chat frame re-anchors
-- to the new instance's container; a tab button gets created on the
-- new instance's strip; the old strip's tab button hides. Multi-tab
-- popped containers are first-class - the new container's "+" button
-- adds tabs to ITSELF, not back to the main dock.
--
-- Popping back in migrates the tab to the main dock instance and
-- destroys the popped container if it has no remaining tabs.
--
-- Container geometry persists in profile.docks[id]; tab membership
-- persists via windows[idx].dockID. The pre-multi-dock popped/popPos
-- fields are migrated into this shape on first load (see
-- MigrateProfileForMultiDock).
---------------------------------------------------------------------------

-- Allocate a fresh popped dockID. Defaults to "pop:<idx>"; if that
-- id is already in use (e.g. user popped, re-popped, popped again)
-- a numeric suffix gets appended until a free id is found.
local function AllocPoppedDockID(idx)
    local p   = GetProfile()
    local pd  = p and p.docks or {}
    local id  = "pop:" .. tostring(idx)
    local seq = 1
    while pd[id] or Window.docks[id] do
        seq = seq + 1
        id = "pop:" .. tostring(idx) .. "_" .. seq
    end
    return id
end

-- Move a tab to a different dock instance. Hides the tab on its old
-- strip, ensures the target strip exists and has a tab button for
-- the window, re-anchors the chat frame, updates profile.windows[idx]
-- .dockID, and selects the migrated tab on the target strip.
function Window:MoveTabToDock(idx, targetDockID)
    if not idx then return end
    targetDockID = targetDockID or "dock"

    local p = GetProfile()
    local ws = p and p.windows and p.windows[idx]
    if not ws then return end
    local oldDockID = ws.dockID or "dock"
    if oldDockID == targetDockID then return end

    -- Hide on the old strip (and pick a successor selection if this
    -- was the active tab there). The button stays in the strip's tabs
    -- table - TabSystem doesn't expose a true "remove" - but it's
    -- hidden and orphaned for the rest of the session. The next
    -- /reload rebuilds strips from scratch via CreateAll.
    local oldTab, oldStrip, oldTabID
    if addon.Tabs then
        oldTab, oldStrip, oldTabID = addon.Tabs:GetTabFor(idx)
    end
    if oldTab then
        oldTab:Hide()
        oldTab._windowIdx = nil   -- sever the back-reference
        if oldStrip and oldStrip.MarkDirty then oldStrip:MarkDirty() end
        if oldStrip and oldStrip.selectedTabID == oldTabID then
            for tID, t in ipairs(oldStrip.tabs or {}) do
                if t:IsShown() and tID ~= oldTabID then
                    oldStrip:SetTab(tID, false)
                    break
                end
            end
        end
    end

    -- Update profile and re-anchor the frame to the target container.
    ws.dockID = targetDockID
    local newInst = Window:CreateDockInstance(targetDockID)
    local f = windows[idx]
    if f then
        f._dockID = targetDockID
        f:ClearAllPoints()
        f:SetAllPoints(newInst.frame)
    end

    -- Add (or reveal) a tab button on the target strip. Tabs:AddFor
    -- is idempotent: if a button already exists for this window on
    -- the target strip (eg the user is yo-yoing pop in / pop out),
    -- it just re-shows it instead of creating a duplicate.
    if addon.Tabs and addon.Tabs.AddFor then
        addon.Tabs:AddFor(f, idx, ws.label or ("Tab " .. idx))
    end

    -- Activate the migrated tab on the target strip so the chat
    -- frame is the visible one in its new container.
    local newStrip, newTabID
    if addon.Tabs then
        local _
        _, newStrip, newTabID = addon.Tabs:GetTabFor(idx)
    end
    if newStrip and newTabID and newStrip.SetTab then
        newStrip:SetTab(newTabID, false)
    end
end

-- Returns true if this tab has at least one other tab in the same
-- container. Used to decide whether "Pop out" is meaningful (splitting
-- the tab into its own new container) vs a no-op (it's already alone
-- in a popped container, which IS its own window).
function Window:HasSiblingsInContainer(idx)
    local ws = WindowProfile(idx)
    if not ws then return false end
    local myID = ws.dockID or "dock"
    local p = GetProfile()
    if not (p and p.windows) then return false end
    for i, w in pairs(p.windows) do
        if i ~= idx and (w.dockID or "dock") == myID then
            return true
        end
    end
    return false
end

-- Enumerate all live dock containers as a sorted array. Each entry:
--   { id, label, tabIndices }
-- The main dock is always first; popped containers follow in dockID
-- order. Labels are user-facing - "Main Chat Window" for the dock,
-- "Window N (firstTab)" for popped instances, with a sibling-count
-- suffix when a popped container holds multiple tabs.
function Window:ListContainers()
    local p = GetProfile()
    local out = {}

    -- Bucket window indices by container.
    local byDock = {}
    if p and p.windows then
        for idx, ws in pairs(p.windows) do
            local id = ws.dockID or "dock"
            byDock[id] = byDock[id] or {}
            table.insert(byDock[id], idx)
        end
    end
    for _, list in pairs(byDock) do
        table.sort(list)
    end

    -- Main dock first.
    out[#out + 1] = {
        id          = "dock",
        label       = "Main Chat Window",
        tabIndices  = byDock["dock"] or {},
    }

    -- Popped containers, sorted by id for stable order.
    local popIDs = {}
    for id in pairs(byDock) do
        if id ~= "dock" then popIDs[#popIDs + 1] = id end
    end
    table.sort(popIDs)

    for i, id in ipairs(popIDs) do
        local idxs = byDock[id]
        local firstLabel = "Tab"
        if idxs[1] and p and p.windows and p.windows[idxs[1]] then
            firstLabel = p.windows[idxs[1]].label or firstLabel
        end
        local label = string.format("Window %d (%s)", i + 1, firstLabel)
        if #idxs > 1 then
            label = label .. string.format(" + %d more", #idxs - 1)
        end
        out[#out + 1] = {
            id         = id,
            label      = label,
            tabIndices = idxs,
        }
    end

    return out
end

-- Move a tab to ANY container (main dock or a popped one). Wraps
-- MoveTabToDock with the lifecycle bits PopIn does: destroy the old
-- popped container if it ends up empty, refresh visibility, update
-- the active container so focus follows the moved tab.
function Window:MoveTab(idx, targetDockID)
    if idx == 1 then return end   -- General is the dock's anchor
    targetDockID = targetDockID or "dock"
    local ws = WindowProfile(idx)
    if not ws then return end
    local oldID = ws.dockID or "dock"
    if oldID == targetDockID then return end

    -- Make sure the destination container exists. For popped targets
    -- the instance was likely already alive (we got the id from
    -- ListContainers); for the main dock CreateDockInstance returns
    -- the cached singleton.
    Window:CreateDockInstance(targetDockID)

    Window:MoveTabToDock(idx, targetDockID)

    -- Destroy the source popped container if no tabs left in it.
    if oldID ~= "dock" then
        local stillHas = false
        local p = GetProfile()
        if p and p.windows then
            for _, w in pairs(p.windows) do
                if (w.dockID or "dock") == oldID then
                    stillHas = true
                    break
                end
            end
        end
        if not stillHas then
            Window:DestroyDockInstance(oldID, true)
        end
    end

    if addon.Tabs and addon.Tabs.UpdateVisibility then
        addon.Tabs:UpdateVisibility()
    end

    Window:SetActiveContainer(targetDockID)
end

function Window:PopOut(idx)
    if idx == 1 then return end   -- General is the dock's anchor
    local f = windows[idx]
    if not f then return end
    local ws = WindowProfile(idx)
    if not ws then return end

    -- A tab can be popped out if it's currently in the dock, OR if
    -- it's in a popped container that holds other tabs (split it into
    -- its own new container). A tab alone in a popped container is
    -- already its own popped window - nothing to do.
    if (ws.dockID or "dock") ~= "dock"
       and not Window:HasSiblingsInContainer(idx) then
        return
    end

    -- Pre-create the popped instance with a fresh id. Migration of
    -- the tab afterwards re-anchors the chat frame to it.
    local newID = AllocPoppedDockID(idx)
    Window:CreateDockInstance(newID, {
        label = "BazChat: " .. (ws.label or ("Tab " .. idx)),
    })
    if BazCore.UpdateEditModeLabel and Window.docks[newID] then
        BazCore:UpdateEditModeLabel(Window.docks[newID].frame,
            "BazChat: " .. (ws.label or ("Tab " .. idx)))
    end

    -- Migrate the tab + chat frame into the new container.
    Window:MoveTabToDock(idx, newID)

    -- Popped windows are always visible - no sibling hides them.
    f:Show()
    if f._bcChromeFrame then f._bcChromeFrame:Show() end

    Window:ApplySettings(idx)

    if addon.Tabs and addon.Tabs.UpdateVisibility then
        addon.Tabs:UpdateVisibility()
    end

    -- The freshly-popped window becomes the active container so the
    -- user's next "/" or Enter routes here without a manual click.
    Window:SetActiveContainer(newID)
end

function Window:PopIn(idx)
    local f = windows[idx]
    if not f then return end
    local ws = WindowProfile(idx)
    if not ws then return end
    local oldDockID = ws.dockID or "dock"
    if oldDockID == "dock" then return end

    Window:MoveTabToDock(idx, "dock")

    -- If the popped container has no remaining tabs, destroy it and
    -- wipe its profile entry. Multi-tab popped containers stick
    -- around until the LAST tab pops in.
    local stillHas = false
    local p = GetProfile()
    if p and p.windows then
        for i, w in pairs(p.windows) do
            if (w.dockID or "dock") == oldDockID then
                stillHas = true
                break
            end
        end
    end
    if not stillHas then
        Window:DestroyDockInstance(oldDockID, true)
    end

    if addon.Tabs and addon.Tabs.UpdateVisibility then
        addon.Tabs:UpdateVisibility()
    end

    -- Active container reverts to the main dock if the popped one
    -- was the active one (or got destroyed above).
    if Window.activeContainer == oldDockID then
        Window:SetActiveContainer("dock")
    end
end

-- IsPopped returns true if the window's tab is currently in any
-- container other than the main dock. Pre-multi-dock callers used
-- this to gate UI affordances ("show Pop in vs Pop out") - the
-- semantics still match.
function Window:IsPopped(idx)
    local ws = WindowProfile(idx)
    return ws and (ws.dockID or "dock") ~= "dock" or false
end

-- DockInstance(id): pop in every tab in a popped container at once.
-- Used by the per-instance edit-mode action "Pop all tabs back to
-- dock" (multi-tab popped containers).
function Window:DockInstance(id)
    if id == "dock" then return end
    local p = GetProfile()
    if not (p and p.windows) then return end
    local toMove = {}
    for idx, ws in pairs(p.windows) do
        if (ws.dockID or "dock") == id then toMove[#toMove + 1] = idx end
    end
    table.sort(toMove)
    for _, idx in ipairs(toMove) do Window:PopIn(idx) end
end

-- Force-redock every popped tab regardless of which container.
-- Recovery path: a popped window may end up off-screen and the only
-- way back is via slash command or the chat-tab context menu.
function Window:DockAllPopped()
    local p = GetProfile()
    if not (p and p.windows) then return end
    local toMove = {}
    for idx, ws in pairs(p.windows) do
        if (ws.dockID or "dock") ~= "dock" then
            toMove[#toMove + 1] = idx
        end
    end
    table.sort(toMove)
    for _, idx in ipairs(toMove) do Window:PopIn(idx) end
end

-- Restore-on-/reload entry point. Pre-multi-dock this used to flip
-- ws.popped + re-PopOut each window. Today the dock instance for
-- each popped tab has already been created automatically (CreateAll
-- iterates windows, each AddFor calls CreateDockInstance(dockID)
-- which is idempotent). All RestorePoppedStates needs to do is make
-- sure popped windows are SHOWN (Window:Create currently hides
-- non-index-1 windows by default) and apply their settings + select
-- the right tab on each popped strip.
function Window:RestorePoppedStates()
    local p = GetProfile()
    if not (p and p.windows) then return end
    for idx, ws in pairs(p.windows) do
        local dockID = ws.dockID or "dock"
        if dockID ~= "dock" and windows[idx] then
            local f = windows[idx]
            local inst = Window.docks[dockID]
            if inst and inst.frame then
                f:ClearAllPoints()
                f:SetAllPoints(inst.frame)
            end
            f._dockID = dockID
            -- Default-show the popped window. The strip's first
            -- SetTab call (made in AddFor) selects the first tab
            -- added to that strip; for multi-tab popped containers
            -- only one tab is shown at a time so siblings get
            -- hidden by the SetTab callback.
            local s = inst and inst.tabSystem
            if s and s.selectedTabID then
                local activeIdx = (addon.Tabs and addon.Tabs:WindowIdxOf(s, s.selectedTabID))
                                  or s.selectedTabID
                f:SetShown(idx == activeIdx)
            else
                f:Show()
            end
            if f._bcChromeFrame then f._bcChromeFrame:Show() end
            Window:ApplySettings(idx)
        end
    end
end
