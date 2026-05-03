-- SPDX-License-Identifier: GPL-2.0-or-later
---------------------------------------------------------------------------
-- BazChat Replica: Init
--
-- Bootstraps the replica chat system at PLAYER_LOGIN. Order:
--   1. Wait for PLAYER_LOGIN (chat frames are guaranteed to exist by
--      then, and BazCoreDB has loaded).
--   2. Hide Blizzard's default chat windows so we don't double-render
--      everything in two places.
--   3. Create our first replica window (BazChatWindow1).
--   4. Start the event router so messages flow into it.
--
-- A separate /reload restores the user's chat exactly as Blizzard
-- left it (Restore() in HideDefault.lua) so disabling the replica
-- never feels destructive.
---------------------------------------------------------------------------

local addonName, addon = ...

local Replica = {}
addon.Replica = Replica

local started = false

function Replica:Start()
    if started then return end

    -- 1. Hide Blizzard's default chat scaffolding so it doesn't
    --    visually overlap our window.
    if addon.HideDefault then addon.HideDefault:Apply() end

    -- 1a. Install the chat-history capture hook (idempotent). This
    --     hooks SendChatMessage so every line the user sends gets
    --     appended to BazChatDB.profile.typedHistory. Safe to call
    --     before windows are created - the hook just appends.
    if addon.History then addon.History:Install() end

    -- 1c. Install global chat filters (suppresses other players'
    --     tradeskill / opening proximity broadcasts so the Loot tab
    --     doesn't flood with "Player creates X" spam in cities).
    if addon.Channels and addon.Channels.InstallFilters then
        addon.Channels:InstallFilters()
    end

    -- 1b. Force-claim ChatFrameUtil.OpenChat (the modern-WoW
    --     replacement for the old ChatFrame_OpenChat). Pressing
    --     Enter / Slash fires this; Blizzard's default logic
    --     chooses an editbox via ChatFrameUtil.ChooseBoxForSend.
    --     Even with our DEFAULT_CHAT_FRAME claim, that chain can
    --     return a stale hidden editbox (e.g. ChatFrame1's pre-
    --     hide one). Hooking AFTER the original runs lets us
    --     re-activate our window-1 editbox if some other editbox
    --     got picked.
    -- Singleton-guard against duplicate hook installs across /reload.
    -- `addon` is a fresh table every load so a flag on it is nil
    -- post-reload; the hook would then stack on top of the previous
    -- session's still-attached hook, and on each subsequent press of
    -- "/" you'd get one SetText("/") call per stacked hook - which is
    -- exactly the "//" bug reported. Storing the flag on the
    -- Blizzard-side ChatFrameUtil table (which persists across
    -- /reload) keeps the install idempotent forever in this session.
    if not (ChatFrameUtil and ChatFrameUtil._bazChatOpenChatHooked)
       and ChatFrameUtil and type(ChatFrameUtil.OpenChat) == "function"
    then
        ChatFrameUtil._bazChatOpenChatHooked = true
        hooksecurefunc(ChatFrameUtil, "OpenChat",
            function(text, chatFrame)
                -- If Blizzard targeted a specific chat frame,
                -- respect that. Otherwise force ours.
                if chatFrame ~= nil then return end
                local w = addon.Window and addon.Window:Get(1)
                if not w or not w.editBox then return end

                -- Force our editbox active when Blizzard didn't pick
                -- it (ChooseBoxForSend can return a stale hidden
                -- editbox even though we own DEFAULT_CHAT_FRAME).
                if ACTIVE_CHAT_EDIT_BOX ~= w.editBox then
                    ChatEdit_ActivateChat(w.editBox)
                end

                -- Blizzard's OpenChat sets editbox.text and
                -- editbox.setText = 1 on the editbox returned by
                -- ChooseBoxForSend so ChatFrameEditBoxMixin:OnUpdate
                -- can apply the text on the next frame. The previous
                -- (v007) dedupe fix tried to suppress our SetText when
                -- the text already matched, but that fired AFTER the
                -- deferred OnUpdate in some sequences and the cursor-
                -- position interaction on a re-SetText could still
                -- produce "//" after a /reload. Clearing the deferred
                -- flags on every BazChat editbox inside our hook
                -- guarantees the OnUpdate path can't fire a second
                -- SetText behind our back: we apply the text exactly
                -- once here and own the result.
                if addon.Window and addon.Window.list then
                    for _, win in pairs(addon.Window.list) do
                        local eb = win and win.editBox
                        if eb then
                            eb.setText = 0
                            eb.text = nil
                        end
                    end
                end

                if text then
                    w.editBox:SetText(text)
                    if w.editBox.SetCursorPosition then
                        w.editBox:SetCursorPosition(#text)
                    end
                end
            end)
    end

    -- 2. Create every window defined in the DB. Phase 3 ships with
    --    General + Guild; new tabs (Whispers, Combat, etc.) come
    --    online by extending DEFAULTS.windows in Core/Init.lua and
    --    /reload - no Lua changes here.
    if addon.Window then addon.Window:CreateAll() end

    started = true

    if addon.core then
        addon.core:Print(string.format("|cff8ce0ffv%s loaded.|r",
            tostring(addon.VERSION or "?")))
    end
end

function Replica:Stop()
    if not started then return end
    if addon.HideDefault then addon.HideDefault:Restore() end
    started = false
end

function Replica:IsRunning() return started end

---------------------------------------------------------------------------
-- Boot
---------------------------------------------------------------------------

BazCore:QueueForLogin(function()
    if not addon.core then return end
    if not addon.core:GetSetting("enabled") then return end
    Replica:Start()
end, "BazChat:Replica:Start")
