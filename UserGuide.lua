-- SPDX-License-Identifier: GPL-2.0-or-later
---------------------------------------------------------------------------
-- BazChat User Manual
--
-- Registered with BazCore so it appears as a "User Manual" sub-tab
-- under BazChat's bottom tab in the standalone Options window.
---------------------------------------------------------------------------

if not BazCore or not BazCore.RegisterUserGuide then return end

BazCore:RegisterUserGuide("BazChat", {
    title = "BazChat",
    intro = "BazChat is a full-stack chat replacement for the Baz Suite. It builds its own chat windows on Blizzard's chat-frame primitives - so the message formatter, hyperlinks, BN whisper routing, edit-box history, and combat log all keep working - while owning the lifecycle, tabs, channel filtering, fade modes, persistence, and timestamp gutter end-to-end. Pick a topic on the left for details.",
    pages = {
        ----------------------------------------------------------------
        -- Welcome
        ----------------------------------------------------------------
        {
            title = "Welcome",
            blocks = {
                { type = "lead",
                  text = "BazChat is the suite's chat addon. It replaces the default Blizzard chat with its own frames - same formatter, same hyperlinks, but with per-tab channel filtering, configurable timestamps, chat persistence, copy-paste, and a streamlined Edit Mode for positioning." },

                { type = "note", style = "info",
                  text = "Open settings via |cffffd700/bazchat|r or |cffffd700/bc|r, or click BazChat's bottom tab in the BazCore Options window." },

                { type = "h2", text = "Features at a glance" },
                { type = "list", items = {
                    "|cffffd700Tabs|r - create, rename, delete, reorder; right-click to pick channels per tab",
                    "|cffffd700Channel filtering|r - per-tab toggles for Say/Guild/Whispers/etc. + named channels (General, Trade)",
                    "|cffffd700Timestamps|r - left-gutter clock with a channel-colored vertical bar tying multi-line messages to their timestamp",
                    "|cffffd700Auto-show tabs|r - hide tabs unless context applies (in a raid, in a city, in combat...)",
                    "|cffffd700Persistent chat|r - history is saved across /reload + relog, replayed when you log back in",
                    "|cffffd700Copy chat|r - icon on every chat frame opens a copy dialog with visible lines pre-selected",
                    "|cffffd700Tradeskill filter|r - suppresses other players' \"X creates Y\" proximity broadcasts",
                }},

                { type = "h2", text = "Slash commands" },
                { type = "table",
                  columns = { "Command", "Effect" },
                  rows = {
                      { "/bazchat",      "Open BazCore Options to BazChat" },
                      { "/bc",           "Same; short alias" },
                      { "/bc copy",      "Open the copy dialog for the active tab" },
                      { "/bc clear",     "Clear the active tab + its persisted history" },
                      { "/clearchat",    "Same as /bc clear (top-level alias)" },
                      { "/cc",           "Same as /clearchat (short)" },
                      { "/bc toggle",    "Master on/off for BazChat" },
                      { "/bc reset",     "Wipe all BazChat saved settings (confirms via reload)" },
                  },
                },
            },
        },

        ----------------------------------------------------------------
        -- Tabs
        ----------------------------------------------------------------
        {
            title = "Tabs",
            blocks = {
                { type = "lead",
                  text = "BazChat starts with four tabs - General, Guild, Trade, Log - and lets you add as many more as fit. Each tab subscribes to its own set of channels and event groups." },

                { type = "h2", text = "Creating + renaming" },
                { type = "list", items = {
                    "|cffffd700+|r button at the right end of the tab strip creates a new tab.",
                    "Right-click any tab to open the channel popup; the |cffffd700Name|r field at the top renames the tab live (Enter to save, Esc to cancel).",
                    "|cffffd700BazChat -> Tabs|r in BazCore options shows every tab as a list with the same name field plus an Edit Channels button.",
                }},

                { type = "h2", text = "Deleting + reordering" },
                { type = "list", items = {
                    "Right-click a tab -> |cffffd700Delete Tab|r removes it. Live cleanup, no /reload required.",
                    "The |cffffd700General|r tab can't be deleted - it owns the DEFAULT_CHAT_FRAME claim that drives Enter-to-chat and addon prints.",
                    "Click and HOLD a tab for ~2 seconds to start dragging it. Drop it to the left or right of another tab to reorder.",
                }},

                { type = "h2", text = "Auto-show" },
                { type = "paragraph",
                  text = "Each tab has an Auto-show setting (on the BazChat -> Tabs options page). The default is |cffffd700Always|r - the tab is always visible. Other modes hide the tab unless a condition holds:" },
                { type = "table",
                  columns = { "Mode", "Tab visible when..." },
                  rows = {
                      { "Always",     "(default) at all times" },
                      { "In a city",  "you are in a sanctuary zone (Stormwind, Orgrimmar, etc.) - default for the Trade tab" },
                      { "In a party", "you are in a party (but not a raid)" },
                      { "In a raid",  "you are in a raid" },
                      { "In combat",  "InCombatLockdown is true" },
                      { "In a battleground / arena", "instanceType is pvp or arena" },
                      { "In a dungeon / raid",       "any IsInInstance condition is true" },
                  },
                },
                { type = "note", style = "tip",
                  text = "If the active tab gets hidden (e.g. you leave a raid with the Raid tab focused), BazChat falls back to General automatically." },

                { type = "h2", text = "Reset" },
                { type = "paragraph",
                  text = "BazChat -> Tabs has a |cffffd700Reset Tabs to Defaults|r button. Wipes user-created tabs, restores the canonical four (General/Guild/Trade/Log) with their preset channels. Preserves your chrome settings (alpha/scale/fade modes) - only tab structure resets." },
            },
        },

        ----------------------------------------------------------------
        -- Channels
        ----------------------------------------------------------------
        {
            title = "Channels",
            blocks = {
                { type = "lead",
                  text = "Every tab has its own channel subscription. Right-click any tab to open a 2-column popup that controls exactly what flows in." },

                { type = "h2", text = "Categories vs. channels" },
                { type = "paragraph",
                  text = "The popup splits into two halves:" },
                { type = "list", items = {
                    "|cffffd700Categories|r - the Blizzard-grouped chat types (Say, Emote, Guild, Whispers, Party, Raid, Battleground, System, Errors, Loot, Skill, Pet Battle, etc.). Each is one toggle.",
                    "|cffffd700Named channels|r - a row per currently-joined channel (General, Trade, LocalDefense, custom channels). Toggle individually so you can have a Trade-only tab or mute LocalDefense globally.",
                }},

                { type = "h2", text = "Channel-colored gutter bar" },
                { type = "paragraph",
                  text = "Every chat line that has a timestamp also gets a 1-pixel-wide vertical bar in the gutter, colored to match the message's chat-type color (green for guild, pink for whispers, yellow for system, the channel's custom color for numbered channels). The bar spans the full height of the message including wrapped lines, so multi-line entries stay visually anchored to their timestamp." },
                { type = "note", style = "info",
                  text = "Bar colors come from |cffffd700ChatTypeInfo|r and update live when you change a channel's color via Blizzard's |cffffd700/chat|r config - no /reload needed." },

                { type = "h2", text = "Channel notices + Guild MOTD" },
                { type = "paragraph",
                  text = "BazChat displays the same join/leave/changed-channel notices the default chat shows, AND fetches the Guild MOTD on /reload + relog (which the live event misses, since it fires before our chat frames register). Live MOTD changes from /gmotd come through normally." },
            },
        },

        ----------------------------------------------------------------
        -- Timestamps
        ----------------------------------------------------------------
        {
            title = "Timestamps",
            blocks = {
                { type = "lead",
                  text = "BazChat renders timestamps as a left gutter alongside the chat body, not as an inline prefix. Wrapped continuations of a long message stay flush with the message body, with the channel-colored bar tying them visually to their timestamp." },

                { type = "h2", text = "Format" },
                { type = "paragraph",
                  text = "The Format dropdown in BazChat -> Settings -> Timestamps offers four presets:" },
                { type = "table",
                  columns = { "Preset", "Example" },
                  rows = {
                      { "24-hour",                "14:32" },
                      { "24-hour with seconds",   "14:32:09" },
                      { "12-hour",                "2:32 PM" },
                      { "12-hour with seconds",   "2:32:09 PM" },
                  },
                },
                { type = "note", style = "tip",
                  text = "Power users can hand-edit |cffffd700BazChatDB.profiles.<active>.BazChat.timestamps.format|r with any strftime string (e.g. |cffffd700%a %H:%M|r for \"Mon 14:32\")." },

                { type = "h2", text = "How it's positioned" },
                { type = "paragraph",
                  text = "When timestamps are on, BazChat shifts each message's render position rightward by the gutter width AND narrows its wrap area accordingly. Wrapped lines align with the body's left edge, not under the timestamp. Toggle timestamps off and the chat body fills the full width with native indented word-wrap." },

                { type = "h2", text = "Historic timestamps" },
                { type = "paragraph",
                  text = "Replayed history (after /reload) re-renders each line with its ORIGINAL capture time, not \"now.\" A message logged at 9 AM still reads |cffffd70009:00:00|r when you log back in at noon - persistence stores the unix time alongside the text." },
            },
        },

        ----------------------------------------------------------------
        -- Persistent history
        ----------------------------------------------------------------
        {
            title = "Persistent history",
            blocks = {
                { type = "lead",
                  text = "Chat survives /reload and full relog. When you come back, BazChat replays the last 500 lines per tab into the chat with a clear |cff8ce0ff--- end of history ---|r separator before live messages start." },

                { type = "h2", text = "Capacity" },
                { type = "paragraph",
                  text = "Persistence is capped at the same value as the |cffffd700History buffer|r slider in BazChat -> Settings -> Behavior. Default is 500 lines per tab; the slider goes 100-2000. Higher numbers use more memory and slow /reload slightly while history replays." },

                { type = "h2", text = "What's persisted" },
                { type = "list", items = {
                    "Message text (raw, without timestamp prefix - the gutter renders fresh)",
                    "Chat-type RGB (so the colored bar reproduces correctly)",
                    "Original unix capture time (used to re-render historic timestamps with their actual moment)",
                }},

                { type = "h2", text = "Wiping history" },
                { type = "list", items = {
                    "|cffffd700/clearchat|r or |cffffd700/cc|r clears the active tab's screen AND its persisted history.",
                    "|cffffd700/bc reset|r wipes ALL BazChat saved settings (full nuke; reloads).",
                }},
            },
        },

        ----------------------------------------------------------------
        -- Copy chat
        ----------------------------------------------------------------
        {
            title = "Copy chat",
            blocks = {
                { type = "lead",
                  text = "WoW chat doesn't let you select text natively - this fixes it." },

                { type = "paragraph",
                  text = "BazChat puts a small chat-icon button at the top-right corner of every chat frame. Click it to open a popup with the last 500 lines from that tab. Inside the popup, click |cffffd700Select All|r and press |cffffd700Ctrl+C|r to copy out." },

                { type = "note", style = "tip",
                  text = "The same dialog is reachable via |cffffd700/bc copy|r - useful if you want to bind it to a key." },

                { type = "h2", text = "What's stripped" },
                { type = "paragraph",
                  text = "Copies always strip Blizzard's |cAARRGGBB color escapes so the result pastes cleanly into Discord, a bug report, or a forum post. Hyperlinks (item / spell / achievement) keep their |H...|h human-readable text." },
            },
        },

        ----------------------------------------------------------------
        -- Auto-hide
        ----------------------------------------------------------------
        {
            title = "Auto-hide",
            blocks = {
                { type = "lead",
                  text = "Background panel, tab strip, and scrollbar each have their own visibility mode. Mix and match for the chrome look you want." },

                { type = "table",
                  columns = { "Mode", "Element behaviour" },
                  rows = {
                      { "Always",    "Visible at all times. (Default for everything.)" },
                      { "On hover",  "Faded in when the cursor is over the chat or tab strip; held for 2 seconds after the last hover; faded out cleanly." },
                      { "On scroll", "Scrollbar-only. Faded in when you scroll or hover the chat, faded out a couple seconds later." },
                      { "Never",     "Element never renders. (Mouse wheel still scrolls.)" },
                  },
                },

                { type = "h2", text = "Unified background + tabs" },
                { type = "paragraph",
                  text = "The |cffffd700Unified|r dropdown overrides Background and Tabs visibility together. Switch it from |cffffd700Independent|r to |cffffd700On hover|r and both elements fade in lockstep - a common preference for a minimal look. The individual dropdowns grey out while Unified is active." },

                { type = "note", style = "info",
                  text = "Edit Mode forces all elements visible while you're laying out the dock - so you don't lose the chat in fog while positioning it." },
            },
        },

        ----------------------------------------------------------------
        -- Architecture
        ----------------------------------------------------------------
        {
            title = "Architecture",
            blocks = {
                { type = "lead",
                  text = "For the curious: how BazChat owns the chat without breaking other addons." },

                { type = "paragraph",
                  text = "BazChat is a |cffffd700Path B|r chat addon - it hides Blizzard's default chat windows and builds its own from Blizzard's primitives:" },
                { type = "list", items = {
                    "|cffffd700ScrollingMessageFrame|r - the underlying message buffer + render. We own one per tab.",
                    "|cffffd700ChatFrameMixin|r - the message formatter (player-name colors, hyperlinks, language tags, etc.). Layered onto our frames so we get formatting for free.",
                    "|cffffd700ChatFrameEditBoxTemplate|r - the input bar (channel selector, language dropdown, autocomplete). Reused per-tab.",
                    "|cffffd700TabSystemTemplate|r - the modern tab strip (the same one Blizzard's housing dashboard uses). One shared instance for the whole dock.",
                }},

                { type = "h2", text = "Compatibility" },
                { type = "list", items = {
                    "BazChat preserves the standard Blizzard chat dispatch and filter pipeline. The standard hooks the game exposes for chat customization continue to work normally.",
                    "|cffffd700DEFAULT_CHAT_FRAME|r is repointed to BazChat's General tab so |cffffd700print()|r, GM whisper routing, and the Enter-to-chat keybind all flow through us.",
                    "Saved Variables live under |cffffd700BazCoreDB.profiles.<profile>.BazChat|r - per-character / per-spec / per-class profiles via BazCore's profile system Just Work.",
                }},

                { type = "h2", text = "Two-column timestamp rendering" },
                { type = "paragraph",
                  text = "The timestamp gutter is implemented by hooking the SMF's RefreshLayout to shift each visibleLine's anchor + narrow its width by the gutter width, and hooking RefreshDisplay to parent per-message overlay FontStrings + texture bars to the gutter. The SMF still handles wrapping inside its own area - we just relocate the area." },

                { type = "note", style = "tip",
                  text = "If something looks wrong, |cffffd700/reload|r always restores the last saved state. Settings persist via BazCoreDB.profiles, so you can't accidentally bork your config." },
            },
        },
    },
})
