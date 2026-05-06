-- SPDX-License-Identifier: GPL-2.0-or-later
---------------------------------------------------------------------------
-- BazChat Replica: Tabs (TabSystem, channel detection, chat-type routing)
--
-- Owns the modern TabSystemTemplate / TabSystemTopButtonTemplate strip
-- shared by every chat window. The selected tab grows taller and glows;
-- unselected tabs are dimmer (all native, no custom rendering).
--
-- Also owns the channel-related helpers (Trade tab visibility based
-- on whether the player can currently use a Trade channel) and the
-- per-tab chat-type binding that routes Enter to the right channel
-- (Guild tab → /g, Trade tab → /<trade-id>, etc.).
--
-- Public API (on addon.Tabs):
--   :Ensure(firstWindow)                -- lazy-create the TabSystem
--   :AddFor(window, index, label)       -- add one tab; returns tabID
--   :UpdateVisibility()                 -- re-evaluate Trade tab show/hide
--   :ApplyChatType(editBox, group)      -- set chat type/channel on editbox
--   :IsTradeUsable()                    -- player can use Trade channel
--   .system                             -- the TabSystem frame (read-only)
--   .addBtn                             -- the floating "+" button (read-only)
---------------------------------------------------------------------------

local addonName, addon = ...

local Tabs = {}
addon.Tabs = Tabs

---------------------------------------------------------------------------
-- chat-tab context menu section
--
-- Registered against the shared "chat-tab" scope so the BazChat
-- entries (Channels / Clear / Delete) sit alongside any other addon
-- that wants to extend tab behaviour (BazTooltipEditor's Inspect,
-- a future log-archiver, etc.). Tabs.lua's OnMouseUp hook below
-- opens the menu on shift+right-click.
---------------------------------------------------------------------------

local function GetBazChatSection(ctx)
    if not ctx or not ctx.index then return end
    local idx = ctx.index
    local tab = ctx.tab

    local items = {
        {
            label = "Channels...",
            onClick = function()
                if addon.Channels and addon.Channels.ShowPopup and tab then
                    addon.Channels:ShowPopup(tab, idx)
                end
            end,
        },
        {
            label = "Clear messages",
            onClick = function()
                local w = addon.Window and addon.Window.Get and addon.Window:Get(idx)
                if w and w.Clear then w:Clear() end
            end,
        },
    }

    -- Pop out / Pop in toggle. The label flips based on the tab's
    -- current popped state.
    if addon.Window and addon.Window.IsPopped then
        if addon.Window:IsPopped(idx) then
            items[#items + 1] = {
                label = "Pop in (re-dock)",
                onClick = function()
                    if addon.Window.PopIn then addon.Window:PopIn(idx) end
                end,
            }
        else
            items[#items + 1] = {
                label = "Pop out",
                onClick = function()
                    if addon.Window.PopOut then addon.Window:PopOut(idx) end
                end,
            }
        end
    end

    -- Tab 1 is the protected default; deletion would orphan the dock
    -- chrome. DeleteTab itself guards this but skipping the entry on
    -- the first tab keeps the menu tidy.
    if idx > 1 then
        items[#items + 1] = {
            label = "Delete tab",
            onClick = function()
                if addon.Tabs and addon.Tabs.DeleteTab then
                    addon.Tabs:DeleteTab(idx)
                end
            end,
        }
    end

    return items
end

if BazCore and BazCore.RegisterContextMenuSection then
    BazCore:RegisterContextMenuSection("chat-tab", "BazChat", GetBazChatSection)
end

---------------------------------------------------------------------------
-- DB / window-list accessors
--
-- These mirror the helpers in Window.lua. Both addon.db and
-- addon.core.db paths are checked: BazCore's onReady (which sets
-- addon.db) fires AFTER QueueForLogin callbacks, so during boot
-- addon.core.db is the only populated path.
---------------------------------------------------------------------------

local function WindowDB(idx)
    local p = (addon.db and addon.db.profile)
        or (addon.core and addon.core.db and addon.core.db.profile)
    return p and p.windows and p.windows[idx] or nil
end

local function WindowList()
    return (addon.Window and addon.Window.list) or {}
end

---------------------------------------------------------------------------
-- Channel detection (Trade tab visibility + chat-type routing)
---------------------------------------------------------------------------

-- Trade channels are joinable only in major cities (sanctuary zones).
-- C_ChatInfo.IsRegionalServiceAvailable() returns true everywhere on
-- modern retail (Blizzard bug); GetZonePVPInfo == "sanctuary" is the
-- accurate signal.
function Tabs:IsTradeUsable()
    local pvpType = GetZonePVPInfo and GetZonePVPInfo() or nil
    return pvpType == "sanctuary"
end

-- Find the Trade channel's runtime ID. Realms can name the trade
-- channel "Trade", "Trade - City", "Trade - <ZoneName>", etc., so an
-- exact GetChannelName("Trade") miss falls through to scanning
-- GetChannelList for any name containing "trade" (case-insensitive).
local function FindTradeChannelID()
    if GetChannelName then
        local id = GetChannelName("Trade")
        if id and id ~= 0 then return id end
    end
    if GetChannelList then
        local channels = { GetChannelList() }
        for i = 1, #channels, 3 do
            local id, name = channels[i], channels[i + 1]
            if name and name:lower():find("trade") then return id end
        end
    end
    return nil
end

-- Native chatType per event group. LOOT (Trade tab) is special-cased
-- in ResolveChatType because it depends on the player's current zone.
local CHAT_TYPE_BY_GROUP = {
    GENERAL = "SAY",
    GUILD   = "GUILD",
    LOOT    = "SAY",   -- only used outside cities; cities use CHANNEL
    LOG     = "SAY",   -- LOG tab is read-only, but we still set
                       -- something defensive in case the editbox shows
}

local function ResolveChatType(group)
    if group == "LOOT" then
        if Tabs:IsTradeUsable() then
            local tradeID = FindTradeChannelID()
            if tradeID then return "CHANNEL", tradeID end
        end
        return "SAY", nil
    end
    return CHAT_TYPE_BY_GROUP[group] or "SAY", nil
end

-- Apply a (chatType, channelTarget) to an edit box and refresh its
-- header. Sets BOTH the legacy `.chatType` field and the modern frame
-- attributes that ChatEdit_UpdateHeader reads.
function Tabs:ApplyChatType(editBox, group)
    local chatType, channelTarget = ResolveChatType(group)
    editBox.chatType = chatType
    editBox:SetAttribute("chatType", chatType)
    if chatType == "CHANNEL" then
        editBox:SetAttribute("channelTarget", channelTarget)
        editBox:SetAttribute("chatTarget", nil)
    else
        editBox:SetAttribute("channelTarget", nil)
        editBox:SetAttribute("chatTarget", nil)
    end
    if ChatEdit_UpdateHeader then
        ChatEdit_UpdateHeader(editBox)
    end
end

---------------------------------------------------------------------------
-- Dynamic tab visibility (autoShow)
--
-- Each tab's `autoShow` field declares when the tab should be visible:
--   "always"   - always shown (default for General / Guild / Log)
--   "city"     - only in major cities (sanctuary zones)  - default for Trade
--   "party"    - only when in a party
--   "raid"     - only when in a raid
--   "combat"   - only during combat
--   "pvp"      - only in battlegrounds / arenas
--   "instance" - only in dungeons / raids / scenarios
--
-- :UpdateVisibility iterates all tabs, evaluates each predicate, and
-- shows/hides the tab to match. If the currently-active tab gets
-- hidden, we fall back to General (idx 1).
--
-- Re-fired on zone change, combat start/end, party/raid roster update.
-- Wiring lives in Window:CreateDock's watcher frame.
---------------------------------------------------------------------------

local function ShouldShowTab(autoShow)
    if not autoShow or autoShow == "always" then return true end
    if autoShow == "city" then
        return GetZonePVPInfo and GetZonePVPInfo() == "sanctuary" or false
    end
    if autoShow == "raid" then
        return IsInRaid and IsInRaid() or false
    end
    if autoShow == "party" then
        -- Match Blizzard convention: "in a party" = grouped but not in raid
        return IsInGroup and IsInGroup() and not (IsInRaid and IsInRaid()) or false
    end
    if autoShow == "combat" then
        return InCombatLockdown and InCombatLockdown() or false
    end
    if autoShow == "pvp" then
        local _, instanceType = IsInInstance()
        return instanceType == "pvp" or instanceType == "arena"
    end
    if autoShow == "instance" then
        local inInstance = IsInInstance and IsInInstance() or false
        return inInstance and true or false
    end
    return true
end

function Tabs:UpdateVisibility()
    local ts = self.system
    if not ts or not ts.tabs then return end

    local p = (addon.db and addon.db.profile)
        or (addon.core and addon.core.db and addon.core.db.profile)

    local layoutChanged   = false
    local activeNeedsSwap = false

    for idx, tab in ipairs(ts.tabs) do
        local ws     = p and p.windows and p.windows[idx]
        -- Popped tabs are hidden from the strip - their floating
        -- chrome's close button is the path back into the dock.
        local should = ShouldShowTab(ws and ws.autoShow) and not (ws and ws.popped)
        if tab:IsShown() ~= should then
            tab:SetShown(should)
            layoutChanged = true
            if not should and ts.selectedTabID == idx then
                activeNeedsSwap = true
            end
        end
    end

    if layoutChanged and ts.MarkDirty then ts:MarkDirty() end
    if activeNeedsSwap then ts:SetTab(1, false) end
end

---------------------------------------------------------------------------
-- TabSystem construction
---------------------------------------------------------------------------

local function BuildAddButton(ts)
    -- Floating "+" button to the right of the tab strip. Just a gold
    -- "+" glyph, no tab chrome (avoids the doubled-shadow problems
    -- that came from squeezing TabSystemTopButtonTemplate into a
    -- narrow width). Stubbed OnClick for now.
    local addBtn = CreateFrame("Button", "BazChatAddTabButton", ts)
    addBtn:SetSize(32, 32)
    addBtn:SetPoint("LEFT", ts, "RIGHT", 8, 0)

    local plus = addBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    local fontFile, _, fontFlags = plus:GetFont()
    plus:SetFont(fontFile, 32, fontFlags or "")
    plus:SetShadowOffset(2, -2)
    plus:SetShadowColor(0, 0, 0, 1)
    plus:SetPoint("CENTER", addBtn, "CENTER", 0, -1)
    plus:SetText("+")
    plus:SetTextColor(1, 0.82, 0)   -- WoW gold
    addBtn.Text = plus

    addBtn:SetScript("OnEnter", function(self) self.Text:SetTextColor(1, 1, 0.6) end)
    addBtn:SetScript("OnLeave", function(self) self.Text:SetTextColor(1, 0.82, 0) end)
    addBtn:SetScript("OnMouseDown", function(self)
        self.Text:ClearAllPoints()
        self.Text:SetPoint("CENTER", self, "CENTER", 1, -3)
        self.Text:SetTextColor(0.75, 0.62, 0.18)
    end)
    addBtn:SetScript("OnMouseUp", function(self)
        self.Text:ClearAllPoints()
        self.Text:SetPoint("CENTER", self, "CENTER", 0, -1)
        if self:IsMouseOver() then
            self.Text:SetTextColor(1, 1, 0.6)
        else
            self.Text:SetTextColor(1, 0.82, 0)
        end
    end)
    addBtn:SetScript("OnClick", function()
        local newIdx, err = Tabs:CreateNewTab("New Tab")
        if not newIdx then
            if addon.core and err then
                addon.core:Print("|cffff8800" .. err .. "|r")
            end
            return
        end
        if addon.core then
            addon.core:Print(string.format(
                "Added Tab %d. Right-click the tab to set its channels, or use BazCore options for full editor.",
                newIdx))
        end
        -- If the BazCore options page is open, refresh it so the new
        -- tab appears in the list immediately.
        if BazCore.RefreshOptions then
            BazCore:RefreshOptions("BazChat-Tabs")
        end
    end)
    return addBtn
end

function Tabs:Ensure(firstWindow)
    if self.system then return self.system end

    -- Parent to UIParent (NOT firstWindow). When the user clicks a
    -- tab we hide the previous window and show the new one - if the
    -- TabSystem were a child of the hidden window it'd vanish too.
    local ts = CreateFrame("Frame", "BazChatTabSystem", UIParent, "TabSystemTemplate")
    if not ts then
        if addon.core then
            addon.core:Print("|cffff4444TabSystemTemplate not found - skipping tabs|r")
        end
        return nil
    end

    ts.tabTemplate = "TabSystemTopButtonTemplate"
    -- Tighter clamp than the housing dashboard's defaults; chat tab
    -- labels are short and we want a compact look against ~440px chats.
    ts.minTabWidth = 60
    ts.maxTabWidth = 120
    if TabSystemMixin and TabSystemMixin.OnLoad then
        TabSystemMixin.OnLoad(ts)
    end

    -- Anchor only - no SetSize. TabSystemTemplate inherits
    -- HorizontalLayoutFrame which sizes from child tabs after MarkDirty
    -- (which AddTab calls). Anchor to the dock so the strip tracks the
    -- chat's position; parent stays UIParent so visibility is independent.
    local dock = (addon.Window and addon.Window.dock) or firstWindow
    ts:SetPoint("BOTTOMLEFT", dock, "TOPLEFT", 6, 9)
    if firstWindow.GetFrameLevel then
        ts:SetFrameLevel(firstWindow:GetFrameLevel() + 20)
    end
    -- Native template is sized for full chrome frames; 0.8 reads as
    -- "chat-tab sized" against our smaller chat box.
    ts:SetScale(0.8)
    ts:Show()

    -- Tab click: show the clicked window, hide the rest, focus its
    -- editbox if isUserAction and the tab supports input. Returns
    -- false so SetTabVisuallySelected still runs.
    ts:SetTabSelectedCallback(function(tabID, isUserAction)
        for idx, win in pairs(WindowList()) do
            local active = idx == tabID
            win:SetShown(active)
            if win.editBox then win.editBox:Hide() end
        end

        -- Instant state-sync for the newly-active window's chrome and
        -- scrollbar so they don't flash to their old alpha (possibly 0
        -- in onhover/onscroll mode) before the per-window hover poller
        -- catches up. SyncWindow is a no-animation alpha set based on
        -- the current cursor position and mode.
        if addon.AutoHide and addon.AutoHide.SyncWindow then
            local newF = WindowList()[tabID]
            if newF then addon.AutoHide:SyncWindow(newF) end
        end

        local w     = WindowList()[tabID]
        local wDB   = WindowDB(tabID)
        local group = wDB and wDB.eventGroup or "GENERAL"
        local readOnly  = group == "LOG"
        local inEditMode = addon.Window and addon.Window.dock
                           and addon.Window.dock._inEditMode

        if isUserAction and w and w.editBox and not readOnly then
            -- Re-assert chat type on every tab switch. Defensive against
            -- Blizzard's chat code occasionally rewriting chatType (e.g.
            -- after /whisper). Trade tab also re-resolves the channel
            -- ID in case the player just /joined or left a Trade channel.
            Tabs:ApplyChatType(w.editBox, group)
            ChatEdit_ActivateChat(w.editBox)
        elseif inEditMode and w and w.editBox and not readOnly then
            -- Edit Mode: keep editbox visible without stealing focus.
            w.editBox:Show()
        end
        return false
    end)

    self.system = ts
    self.addBtn = BuildAddButton(ts)
    -- Hover-to-reveal for the "onhover" tabsMode (no-op in always/never).
    if addon.AutoHide then addon.AutoHide:WireTab(self.addBtn) end

    return ts
end

---------------------------------------------------------------------------
-- :AddFor — add one tab to the system. Returns the tab's ID.
---------------------------------------------------------------------------

function Tabs:AddFor(window, index, label)
    local ts = self:Ensure(window)
    if not ts then return nil end

    local tabID = ts:AddTab(label or "Chat")
    if index == 1 then ts:SetTab(tabID) end

    local tab = ts.tabs and ts.tabs[tabID]
    if tab and addon.TabDrag then
        addon.TabDrag:Setup(tab, tabID, ts)
    end
    if tab and addon.AutoHide then
        addon.AutoHide:WireTab(tab)
    end
    -- Shift+right-click on a tab opens BazCore's shared context menu
    -- (scope "chat-tab"). BazChat contributes Channels / Clear / Delete
    -- to that menu via RegisterContextMenuSection further down; other
    -- addons can append their own entries against the same scope.
    -- Plain right-click is intentionally left alone now that the
    -- channel popup lives inside the menu.
    if tab then
        tab:HookScript("OnMouseUp", function(self, button)
            if button == "RightButton" and IsShiftKeyDown() and BazCore.OpenContextMenu then
                BazCore:OpenContextMenu("chat-tab", self, {
                    tab   = self,
                    index = index,
                })
            end
        end)
    end

    return tabID
end

---------------------------------------------------------------------------
-- :CreateNewTab — add a new tab with default channels, return new idx.
--
-- Used by:
--   * The "+" button on the tab strip (OnClick handler)
--   * The "Create New Tab" button on the Tabs options page
-- Both flows hand off to here so behavior stays identical.
--
-- Default channels = "BLANK" preset (just Say) to keep new tabs quiet
-- until the user picks what they want via the channel popup.
---------------------------------------------------------------------------

function Tabs:CreateNewTab(label)
    local p = (addon.db and addon.db.profile)
        or (addon.core and addon.core.db and addon.core.db.profile)
    if not p then return nil end
    p.windows = p.windows or {}

    -- Refuse if there's no room. Sum the ACTUAL widths of currently-
    -- visible tabs (tabs render between minTabWidth and maxTabWidth
    -- based on label length, so projecting minTabWidth × count under-
    -- estimates real usage). Add minTabWidth for the projected new tab,
    -- plus 40 px for the "+" button slot (32 px button + 8 px gap).
    -- Multiply by the strip's scale to get screen pixels and compare
    -- against the dock's width.
    local ts = self.system
    if ts and ts.tabs then
        local stripW = 0
        for _, t in ipairs(ts.tabs) do
            if t:IsShown() then stripW = stripW + (t:GetWidth() or 0) end
        end
        local newTabW = ts.minTabWidth or 60
        local addBtn  = 40
        local scale   = ts:GetScale() or 1
        local dock    = addon.Window and addon.Window.dock
        local dockW   = dock and dock:GetWidth() or 440
        local projectedScreen = (stripW + newTabW + addBtn) * scale
        if projectedScreen > dockW then
            return nil, "tab strip is full at this chat width - delete a tab first"
        end
    end

    -- Find the next free index. Walk past existing windows[] to handle
    -- gaps from previous deletes.
    local nextIdx = 1
    while p.windows[nextIdx] do nextIdx = nextIdx + 1 end

    p.windows[nextIdx] = {
        label    = label or "New Tab",
        channels = addon.Channels and addon.Channels:DefaultsFor("BLANK") or {},
    }

    -- Instantiate the chat frame + tab button live (no /reload).
    if addon.Window and addon.Window.Create then
        addon.Window:Create(nextIdx, { label = p.windows[nextIdx].label })
    end

    return nextIdx
end

---------------------------------------------------------------------------
-- :DeleteTab — remove a tab by index. General (idx 1) is undeletable
-- because it owns the DEFAULT_CHAT_FRAME claim.
--
-- Approach: clear the DB entry then reload. Compacting in-memory across
-- a deletion would require shifting every windows[] / tabs[] / tabOrder
-- entry above the deleted index, plus reindexing live frames - the
-- /reload trade-off is "1 second to settle, guaranteed clean state."
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- :ResetTabsToDefaults — wipe user customizations + restore the four
-- canonical tabs (General/Guild/Trade/Log) with their preset channels.
--
-- Triggers a /reload so the live state rebuilds cleanly. Useful as
-- the "panic button" when a user deletes/renames things and wants to
-- start over without nuking their whole BazChat profile.
---------------------------------------------------------------------------

function Tabs:ResetTabsToDefaults()
    local p = (addon.db and addon.db.profile)
        or (addon.core and addon.core.db and addon.core.db.profile)
    if not p then return false end

    -- Wipe windows[] and tab-related metadata. windows[1]'s chrome
    -- settings (alpha/scale/fade modes) are preserved by reading them
    -- before the wipe and re-applying after - the user's appearance
    -- preferences shouldn't get reset just because they wanted tabs back.
    local preserve = {}
    if p.windows and p.windows[1] then
        for _, key in ipairs({
            "alpha", "bgAlpha", "bgMode", "tabsAlpha", "chromeFadeMode",
            "scale", "scrollbarMode", "tabsMode", "fading", "fadeDuration",
            "timeVisible", "maxLines", "indentedWordWrap",
            "width", "height", "pos",
        }) do
            preserve[key] = p.windows[1][key]
        end
    end
    p.windows = nil
    p.deletedCanonicals = nil
    p.tabOrder = nil

    -- Re-stamp window 1's chrome settings so CreateAll's migration
    -- doesn't overwrite them with raw defaults.
    p.windows = { [1] = preserve }

    return true
end

function Tabs:DeleteTab(idx)
    if idx == 1 then return false end
    local p = (addon.db and addon.db.profile)
        or (addon.core and addon.core.db and addon.core.db.profile)
    if not p or not p.windows or not p.windows[idx] then return false end

    -- Live cleanup: hide the chat frame and the tab button so they
    -- vanish without a /reload. The runtime tables (Window.list, the
    -- TabSystem's tabs array) still hold references; that's a harmless
    -- memory leak that gets cleaned up on next /reload (CreateAll
    -- iterates the DB only). Avoids the trickier in-memory compaction
    -- of windows[] / tabs[] / tabSystem.tabs which would require
    -- reindexing every entry above the deleted position.
    local list = (addon.Window and addon.Window.list) or {}
    local f = list[idx]
    if f then f:Hide() end
    if self.system and self.system.tabs and self.system.tabs[idx] then
        self.system.tabs[idx]:Hide()
        if self.system.MarkDirty then self.system:MarkDirty() end
    end

    -- If the deleted tab was the active one, fall back to General.
    if self.system and self.system.selectedTabID == idx then
        self.system:SetTab(1, false)
    end

    -- Wipe the DB entry. From this point any code reading
    -- windows[idx] from the profile sees nil, so right-click /
    -- channel-popup / options-page entries all become inert for it.
    p.windows[idx] = nil

    -- Track explicit deletions of CANONICAL tabs (Guild=2, Trade=3,
    -- Log=4). Without this, CreateAll's migration would re-create them
    -- on the next /reload because the canonical entry was missing.
    -- User-created tabs (idx 5+) don't need tracking - the canonical
    -- iteration only runs for 1..4, so a deleted user tab simply
    -- isn't seen on reload.
    if idx >= 2 and idx <= 4 then
        p.deletedCanonicals = p.deletedCanonicals or {}
        p.deletedCanonicals[idx] = true
    end

    -- Also strip the deleted index out of any saved tab order so
    -- TabDrag:LoadOrder doesn't reference a now-missing window on
    -- the next reload.
    if p.tabOrder then
        local cleaned = {}
        for _, id in ipairs(p.tabOrder) do
            if id ~= idx then cleaned[#cleaned + 1] = id end
        end
        p.tabOrder = cleaned
    end

    -- Close the channel popup if it was for this tab; refresh the
    -- BazCore Tabs options page so the row disappears from the list.
    if addon.Channels and addon.Channels.HidePopup then
        addon.Channels:HidePopup()
    end
    if BazCore.RefreshOptions then
        BazCore:RefreshOptions("BazChat-Tabs")
    end

    return true
end
