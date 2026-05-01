---------------------------------------------------------------------------
-- BazChat Module: Copy Chat
--
-- Adds a small clickable icon to every chat frame. Click it (or use
-- /bc copy) to pop the BazCore:OpenCopyDialog with the visible chat
-- history pre-selected and ready to Ctrl+C. Solves the "WoW chat is
-- not natively selectable" problem with code we already wrote in
-- BazCore/CopyDialog.lua.
---------------------------------------------------------------------------

local addonName, addon = ...

local M = {
    id    = "copyChat",
    label = "Copy Chat",
}

-- Per-frame button registry so we don't double-attach if Refresh
-- re-runs (e.g. after a settings change).
local buttons = {}

---------------------------------------------------------------------------
-- Build the button on a single chat frame.
---------------------------------------------------------------------------

local function CreateButton(chatFrame)
    if buttons[chatFrame] then return buttons[chatFrame] end

    local size = (addon.db and addon.db.profile.copyChat.iconSize) or 16
    local btn = CreateFrame("Button", nil, chatFrame)
    btn:SetSize(size, size)
    -- Sit just inside the chat frame's top-right corner. The chat
    -- frame's own scroll-down arrow lives a bit further down, so the
    -- top-right is clear real estate even on the default UI.
    btn:SetPoint("TOPRIGHT", chatFrame, "TOPRIGHT", -2, -2)
    btn:SetFrameStrata("DIALOG")        -- above chat content
    btn:SetFrameLevel((chatFrame:GetFrameLevel() or 0) + 5)

    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture(2056011)             -- ui_chat
    tex:SetVertexColor(1, 1, 1, 0.55)
    btn.tex = tex

    btn:SetScript("OnEnter", function(self)
        self.tex:SetVertexColor(1, 0.82, 0, 1)
        if BazCore.Tooltip then
            BazCore:Tooltip(self, "Copy chat to dialog", "ANCHOR_LEFT")
        end
    end)
    btn:SetScript("OnLeave", function(self)
        self.tex:SetVertexColor(1, 1, 1, 0.55)
        GameTooltip:Hide()
    end)
    btn:SetScript("OnClick", function()
        BazChat:OpenCopyForFrame(chatFrame)
    end)

    buttons[chatFrame] = btn
    return btn
end

---------------------------------------------------------------------------
-- Public: open the copy dialog for a specific (or active) chat frame.
---------------------------------------------------------------------------

local function FormatLines(lines, stripColors)
    if not lines or #lines == 0 then return "" end
    local out = {}
    for i, line in ipairs(lines) do
        out[i] = stripColors and addon:StripColorCodes(line) or line
    end
    return table.concat(out, "\n")
end

function BazChat:OpenCopyForFrame(chatFrame)
    chatFrame = chatFrame or addon:ActiveChatFrame()
    if not chatFrame then return end

    local lines = addon:GetChatLines(chatFrame, 500)
    -- WoW chat colour codes (|cAARRGGBB...|r) survive paste into most
    -- editors as garbage. Strip them by default; future setting can
    -- expose a "keep colors" toggle if anyone asks for it.
    local content = FormatLines(lines, true)
    if not BazCore.OpenCopyDialog then
        if addon.core then addon.core:Print("BazCore:OpenCopyDialog not available") end
        return
    end

    local tabName = (chatFrame.name) or ("ChatFrame" .. (chatFrame:GetID() or "?"))
    BazCore:OpenCopyDialog({
        title    = "BazChat Export - " .. tabName,
        subtitle = string.format("%d line(s) from this tab. Ctrl+A then Ctrl+C to copy.", #lines),
        content  = content,
    })
end

function BazChat:OpenCopyForActiveFrame()
    return self:OpenCopyForFrame(addon:ActiveChatFrame())
end

---------------------------------------------------------------------------
-- Module lifecycle
---------------------------------------------------------------------------

function M:Init()
    self:Refresh()
end

function M:Refresh()
    local enabled = addon.db
        and addon.db.profile.copyChat
        and addon.db.profile.copyChat.enabled

    addon:IterateChatFrames(function(cf)
        if enabled then
            local btn = CreateButton(cf)
            btn:Show()
        else
            local btn = buttons[cf]
            if btn then btn:Hide() end
        end
    end)
end

BazChat:RegisterModule(M)
