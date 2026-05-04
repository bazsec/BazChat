> **Warning: Requires [BazCore](https://www.curseforge.com/wow/addons/bazcore).** If you use the CurseForge app, it will be installed automatically. Manual users must install BazCore separately.

# BazChat

![Part of BazAddons](https://img.shields.io/badge/Part_of-BazAddons-b8924a?labelColor=2a2519) ![WoW](https://img.shields.io/badge/WoW-12.0_Midnight-blue) ![License](https://img.shields.io/badge/License-GPL_v2-green) ![Version](https://img.shields.io/github/v/tag/BazAddons/BazChat?label=Version&color=orange)

Modern chat replacement with per-tab channel filtering, persistent history across /reload, two-column timestamps with channel-colored gutter bars, auto-show tabs, and built-in copy-paste.

BazChat is a full-stack chat replacement built on Blizzard's chat primitives — `ScrollingMessageFrame`, `ChatFrameMixin`, `ChatFrameEditBoxTemplate`, `TabSystemTemplate`. It hides Blizzard's default chat windows and creates its own, so it owns the lifecycle, tabs, channel filtering, fade modes, persistence, and timestamp rendering end-to-end. The Blizzard message formatter, hyperlinks, edit-box history, BN whisper routing, and combat log all keep working untouched — they're the same primitives, just composed differently.

Each tab has its own independent channel subscription. Right-click any tab to open a 2-column popup that lists every chat category (Say, Emote, Guild, Whispers, Party, Raid, etc.) plus every currently-joined channel (General, Trade, LocalDefense) as individual toggles. You can have a Whispers-only tab, a Trade-only tab, a Combat Log tab — whatever fits your workflow.

Timestamps render as a left **gutter** alongside the chat body, not as an inline prefix. A 1-pixel vertical bar between the timestamp and message body is colored to match each message's chat type — green for guild, pink for whispers, yellow for system, the channel's custom color for numbered channels — giving you at-a-glance scanability of message types in a busy chat. Wrapped continuations stay visually anchored to their timestamp.

Chat persists across `/reload` and relog. The last 500 lines per tab are saved to `BazCoreDB` and replayed when you log back in, with a clear `--- end of history ---` separator before live messages start. Replayed lines re-render with their **original** capture time in the gutter, not "now."

***

## Features

### Full Chat Replica

*   **Path B architecture** — Blizzard's default chat is hidden; BazChat owns the windows from scratch
*   **`ChatFrameMixin` layered onto our frames** — message formatter, hyperlinks, language tags, color codes all work natively
*   **`DEFAULT_CHAT_FRAME` repointed** — `print()`, GM whisper routing, and the Enter-to-chat keybind all flow through us
*   **Compatibility** — preserves the standard Blizzard chat dispatch and filter pipeline; the standard hooks the game exposes for chat customization continue to work normally

### Tabs

*   **Default set** — General, Guild, Trade, Log, plus a `+` button to create as many more as fit
*   **Right-click any tab** to open the channel + rename + delete popup
*   **Hold a tab for ~2 seconds** to drag-reorder; drop position persists across `/reload`
*   **BazCore options page** for tab management (rename, delete, edit channels, auto-show mode)
*   **General tab is undeletable** — owns the `DEFAULT_CHAT_FRAME` claim
*   **Reset Tabs to Defaults** button restores the canonical four with their preset channels

### Auto-Show Tabs

Each tab has an auto-show setting that conditionally hides it unless the listed condition is met:

| Mode | Tab visible when... |
| --- | --- |
| Always | (default) at all times |
| In a city | you're in a sanctuary zone (Stormwind, Orgrimmar, Valdrakken, etc.) — default for the Trade tab |
| In a party | you're in a party (but not a raid) |
| In a raid | you're in a raid |
| In combat | `InCombatLockdown` is true |
| In a battleground / arena | `instanceType` is `pvp` or `arena` |
| In a dungeon / raid | any `IsInInstance` condition is true |

If the active tab gets hidden (e.g. you leave a raid with the Raid tab focused), BazChat falls back to General automatically.

### Channel Filtering

*   **Per-tab toggles** for every chat category and every currently-joined channel
*   **2-column popup** anchored under the right-clicked tab
*   **Channel-colored gutter bar** per message — pulled from `ChatTypeInfo` so it updates live when you change a channel's color via Blizzard's `/chat` config
*   **Channel notice rendering** — `[Joined Channel]`, `[Left Channel]`, `[Changed Channel]` all flow through normally
*   **Guild MOTD recovery on `/reload` + relog** — the live `GUILD_MOTD` event fires before our chat frames register, so we manually fetch the cached MOTD and render it
*   **Tradeskill spam filter** — suppresses other players' "X creates Y" proximity broadcasts so the Loot tab doesn't flood in cities

### Two-Column Timestamps

*   **Left gutter rendering** with a per-message vertical bar tinted to the message's chat type color
*   **Format dropdown** with four presets: 24-hour, 24-hour with seconds, 12-hour, 12-hour with seconds. Power users can hand-edit the strftime string in the saved variable for locale-specific formats
*   **Date tooltip on hover** — hover any timestamp for a tooltip showing the full date (`Thursday, April 30, 2026`)
*   **Wrap-aware** — wrapped continuations of a long message align with the message body, not under the timestamp
*   **Historic stamps preserve original time** — a message logged at 9 AM still reads `09:00:00` when you log back in at noon

### Persistent History

*   **500 lines per tab** saved across `/reload` and relog (configurable, 100-2000)
*   **End-of-history separator** clearly bracketed with blank lines before live messages start
*   **Channel-color preserved** — each line's r/g/b is stored alongside text so the gutter bar reproduces correctly
*   **`/clearchat`** wipes the active tab + its persisted history

### Channel Names

Shortens bracketed channel prefixes for less horizontal noise:

| Channel | Default short |
| --- | --- |
| Guild | g |
| Officer | o |
| Party | p |
| Party Leader | pl |
| Raid | r |
| Raid Leader | rl |
| Raid Warning | rw |
| Instance Chat | i |
| Battleground | bg |
| Whisper to me | w |
| Whisper from me | to |

Plus an option to strip numeric prefixes from custom channels: `[1. Trade - Stormwind]` → `[Trade]`.

### Copy Chat

*   **Small icon** on the top-right of every chat frame — click to open a copy dialog
*   **Last 500 visible lines** of that tab pre-selected, ready for `Ctrl+A` / `Ctrl+C`
*   **Color codes stripped** — clean paste into Discord, bug reports, forums
*   **Hyperlinks preserved** — `|H...|h` text is human-readable
*   Also reachable via `/bc copy`

### Auto-Hide Modes

Background panel, tab strip, and scrollbar each have their own visibility mode:

| Mode | Element behaviour |
| --- | --- |
| Always | visible at all times (default for everything) |
| On hover | faded in when the cursor is over the chat or tab strip; held 2 seconds after last hover; faded out cleanly |
| On scroll | scrollbar-only — fades in when you scroll or hover the chat, fades out a couple seconds later |
| Never | element never renders (mouse wheel still scrolls) |

A **Unified background + tabs** override forces both to share a single mode for a minimal look.

### Edit Mode Integration

*   **Native `RegisterEditModeFrame`** integration via BazCore
*   **Inline settings popup** with opacity, scale, and visibility-mode controls
*   **Position nudge** for pixel-precise placement
*   **All chat windows + tabs move rigidly** as a single dock when you drag

### Typed Message History

*   **Up/Down arrows** in the edit box cycle previous messages
*   **Persists across `/reload` and relog** — saved to `BazCoreDB`
*   Captured at `C_ChatInfo.SendChatMessage` so all send paths land in the buffer

***

## Slash Commands

| Command | Description |
| --- | --- |
| `/bazchat` or `/bc` | Open BazCore Options to BazChat |
| `/bc copy` | Open the copy dialog for the active tab |
| `/bc clear` | Clear the active tab + its persisted history |
| `/clearchat` or `/cc` | Alias for `/bc clear` |
| `/bc toggle` | Master on/off for BazChat |
| `/bc reset` | Wipe all BazChat saved settings (confirms via reload) |

***

## Installation

### CurseForge / WoW Addon Manager

Search for **BazChat** in your addon manager of choice. BazCore will be installed automatically as a dependency.

### Manual Installation

1.  Install [BazCore](https://www.curseforge.com/wow/addons/bazcore) first
2.  Download the latest BazChat release
3.  Extract to `World of Warcraft/_retail_/Interface/AddOns/BazChat/`
4.  Restart WoW or `/reload`

***

## Compatibility

| | |
| --- | --- |
| **WoW Version** | Retail 12.0 (Midnight) |
| **Combat** | Chat is non-secure; all features work in combat |
| **Other chat addons** | Compatible — preserves the standard chat dispatch and filter pipeline |
| **Profiles** | Per-character / per-spec / per-class via BazCore |

***

## Dependencies

**Required:**

*   [BazCore](https://www.curseforge.com/wow/addons/bazcore) — shared framework for Baz Suite addons (provides profiles, options window, copy dialog, settings spec)

***

## License

BazChat is licensed under the **GNU General Public License v2** (GPL v2).

---

<p align="center">
  <sub>Built with engineering precision by <strong>Baz4k</strong></sub>
</p>
