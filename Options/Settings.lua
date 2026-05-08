-- SPDX-License-Identifier: GPL-2.0-or-later
---------------------------------------------------------------------------
-- BazChat Settings page
--
-- Built from the unified SettingsSpec (Replica/SettingsSpec.lua) via
-- BazCore:BuildOptionsTableFromSpec. The Edit Mode popup in
-- Replica/Window.lua reads from the same spec - so the two surfaces
-- stay aligned automatically. Adding a new chrome/behavior setting
-- means editing one place (the spec); both panels pick it up.
--
-- Registered as a sub-page under BazChat's bottom tab in BazCore's
-- standalone options window.
---------------------------------------------------------------------------

local addonName, addon = ...

local PAGE_KEY = "BazChat-Settings"

local INTRO =
    "BazChat is a full chat replacement built on top of Blizzard's own "
    .. "ChatFrameMixin formatter. These options control the chat dock's "
    .. "chrome and behavior and apply to every tab. The same controls also "
    .. "live inline in Edit Mode - both views edit the same saved settings, "
    .. "so changes here mirror live to the popup and vice versa."

---------------------------------------------------------------------------
-- Register with BazCore
---------------------------------------------------------------------------

BazCore:QueueForLogin(function()
    if not BazCore.RegisterOptionsTable then return end
    if not BazCore.BuildOptionsTableFromSpec then return end

    local function BuildPage()
        return BazCore:BuildOptionsTableFromSpec(addonName, {
            name  = "BazChat",
            intro = INTRO,
        })
    end

    -- Top-level addon entry (becomes the bottom tab in the BazCore
    -- standalone options window).
    BazCore:RegisterOptionsTable(addonName, BuildPage)
    BazCore:AddToSettings(addonName, "BazChat")

    -- Settings sub-category in the left sidebar under BazChat.
    BazCore:RegisterOptionsTable(PAGE_KEY, BuildPage)
    BazCore:AddToSettings(PAGE_KEY, "Settings", addonName)
end)
