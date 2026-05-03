# BazChat changelog

## 021 — Log tab: keep chrome full-size when SMF is inset

v019/v020 inset the Log frame's SMF top by 26 px to make room for the QuickButton bar. The NineSlice chrome panel (Replica/Chrome.lua) anchors to the SMF's corners, so when the SMF shrunk the chrome shrunk with it — the Log tab's visible chat box ended up 26 px shorter than the other tabs. The user's intent was to shrink the *log content area* without changing the *background size*.

`Replica/CombatLog.lua` now also re-anchors the Log frame's chrome to the dock instead of the SMF (with the same Chrome.lua INSET\_\* offsets, hardcoded here). The chrome stays the same size as the other tabs' chromes; only the SMF text-rendering area is inset to make room for the bar.

## 020 — Log tab: anchor inset to the dock, not UIParent

v019 anchored the inset Log frame to `targetFrame:GetParent()`, but the chat windows are parented to UIParent and only `SetAllPoints` to the dock — so my four-point anchor stretched the Log frame to fill the entire screen instead of the dock. Anchoring to `addon.Window.dock` directly fixes it.

## 019 — Log tab: inset the chat content so the QuickButton bar fits

v018 anchored the combat-log filter bar above the Log frame (Blizzard's default placement, BOTTOMLEFT-to-TOPLEFT of `COMBATLOG`), but BazChat's tab strip already sits above the chat frame so the two collided — preset buttons rendered behind the tabs.

Now the Log frame's top edge is pushed down by 26 px (the bar's height + a small padding) via a four-point anchor on its dock parent. The QuickButton bar fills that newly-vacated gap. Final stack: tabs (above dock) → bar (top 26 px of dock) → chat content (remainder), matching the Blizzard layout exactly.

## 018 — Log tab: hijack Blizzard's combat log

The Log tab now replicates Blizzard's combat log experience: formatted `COMBAT_LOG_EVENT_UNFILTERED` lines (per-school colors, source/dest/spell/amount coloring, the standard "Your <spell> hit <target> for <amount> <school>." templates) plus the filter UI bar at the top with the preset quick-buttons (`My actions`, `What happened to me?`, any user-saved presets) and the `Additional Filters` dropdown.

Implementation: a new `Replica/CombatLog.lua` rebinds `_G.COMBATLOG` from `ChatFrame2` (which BazChat hides) to our Log window, then reparents `CombatLogQuickButtonFrame_Custom` onto our Log frame and re-runs `Blizzard_CombatLog_Update_QuickButtons` so the preset buttons re-layout against our frame's width. Blizzard's `CombatLogDriverMixin` keeps doing the parsing and formatting; we just redirect where it writes. Wired into `Replica:Start` after `Window:CreateAll`. Falls back to an `ADDON_LOADED` watcher if `Blizzard_CombatLog` (load-on-demand) hasn't loaded yet.

## 017 — Guild MOTD: module-scope listener decoupled from window lifecycle

v016 installed a per-window event listener inside `DisplayInitialMOTD`. If GUILD_MOTD or PLAYER_GUILD_UPDATE fired before the window was fully wired (e.g. on a fast cold login where guild data lands during Window:Create), the listener could miss the event because frame scripts weren't yet active.

Switched to a single module-scope listener created at file-load time. It listens for `GUILD_MOTD`, `PLAYER_GUILD_UPDATE`, and `PLAYER_ENTERING_WORLD`, and resolves `addon.Window:Get(1)` lazily inside the handler. First non-empty MOTD that successfully renders on window 1 wins; the listener tears down after. `DisplayInitialMOTD` is kept as a thin synchronous attempt for the warm /reload case but the durable mechanism is the module-scope listener.

## 016 — Guild MOTD: event-driven render

Replaced the polling retry in `DisplayInitialMOTD` with an event-driven listener: the function now tries an immediate `C_GuildInfo.GetMOTD()` (covers `/reload` warm-data path), and if that returns empty it registers a one-shot listener for `GUILD_MOTD` (server pushes during guild-data load), `PLAYER_GUILD_UPDATE` (guild membership finalised), and `PLAYER_ENTERING_WORLD` (final fallback). First event with non-empty MOTD renders, listener tears itself down. More reliable than the previous 5-second polling window on slow cold logins. v015's "primary window only" routing is preserved.

## 015 — Guild MOTD: always render on primary window

v014 added direct `AddMessage` rendering for the cold-login MOTD recovery, but `DisplayInitialMOTD` was still bailing when the calling window's `ws.channels.guild` flag was false. Users who split Guild chat to a dedicated tab had `channels.guild = false` on their primary General tab, so MOTD was silently skipped there. Live `GUILD_MOTD` events through the mixin path still routed to the Guild tab correctly, but the cold-login *recovery* didn't surface anywhere visible.

Two changes:
- `Window.lua` only calls `DisplayInitialMOTD` for window 1 (the primary view).
- `DisplayInitialMOTD` no longer gates on `ws.channels.guild`. It always renders on the calling frame.

Net result: MOTD displays exactly once on login, on the primary chat window, regardless of the user's per-tab channel routing.

## 014 — Guild MOTD: pull and display ourselves instead of routing through ChatFrameUtil

v013 still went through `ChatFrameUtil.DisplayGMOTD` which apparently doesn't always render on our replica window in modern WoW. Replaced that call with a direct `frame:AddMessage(...)`: fetch the cached MOTD via `C_GuildInfo.GetMOTD()`, format with `GUILD_MOTD_TEMPLATE` ("Guild Message of the Day: %s"), color from `ChatTypeInfo["GUILD"]` (standard guild green), feed straight into our AddMessage chain. Same retry behavior as v013 (up to 10 attempts at 0.5s intervals to ride out the cold-login guild-data race).

## 013 — Fix: Guild MOTD missing after /reload + cold login

`Channels:DisplayInitialMOTD` ran once at window-create time (during `Replica:Start` at PLAYER_LOGIN), which is too early on a cold login — `IsInGuild()` and `C_GuildInfo.GetMOTD()` haven't returned valid data yet, so the MOTD recovery silently bailed. Live `GUILD_MOTD` events for `/gmotd` changes still worked since they hit the subscribed mixin, but the *cached* MOTD from session start was lost.

Added a retry loop: up to 10 attempts at 0.5s intervals (~5 seconds total) until guild data is available, then `ChatFrameUtil.DisplayGMOTD` fires once. Bails immediately if the user isn't in a guild.

## 012 — Drop redundant per-addon load print + fix UP returning post-parse form

Two changes:

**1. UP arrow returning post-parse form ("hi") instead of typed input ("/say hi")**

v009 dropped the `AddHistoryLine` hook and added an `OnEnterPressed` pre-hook that captures the editbox's raw text before Blizzard's parser runs. That alone is correct — but the `C_ChatInfo.SendChatMessage` and legacy `SendChatMessage` hooks were still firing as redundancy, and they receive the *post-parse* text. Blizzard's `ProcessChatType` rewrites the editbox from "/say hi" to "hi" and changes the chat type, then `SendText` calls `C_ChatInfo.SendChatMessage("hi", "SAY", ...)`. Net result: typing "/say hi" added two entries — the raw "/say hi" from the pre-hook, then "hi" from the SendChatMessage hook. UP returned "hi" even though the user expected "/say hi" back.

Dropped both `SendChatMessage` hooks. Capture now lives entirely in `History:Apply`'s per-editbox `OnEnterPressed` pre-hook, which gives us the user's actual typed input regardless of which send path Blizzard takes.

**2. Drop redundant per-addon load print**

BazCore v102 prints a unified "BazCore vXXX, BazBars vYYY, BazChat vZZZ, ..." welcome line on login that already includes BazChat. Removed the BazChat-specific "vXXX loaded." print so the user sees one line for the whole suite instead of one suite-line plus a duplicate BazChat-line.

## 011 — Stop calling SetText ourselves on OpenChat (real "//" fix)

v010 cleared `editbox.setText`/`editbox.text` to suppress Blizzard's deferred path, then called `SetText` ourselves. That still produced "//" — the literal "/" keypress also fires `OnChar` on our editbox when it gains focus mid-press, and our explicit `SetText("/")` landed on top of that delivery (or vice versa) producing two slashes. The fix is to stop calling `SetText` at all and let Blizzard's deferred `OnUpdate` path own the text application, in sync with the keypress consumption.

`OpenChat` hook now:
- If `ACTIVE_CHAT_EDIT_BOX` is already our editbox: do nothing (Blizzard picked us; deferred path applies the text correctly).
- Otherwise: activate our editbox, copy the deferred-text state (`editbox.text` + `editbox.setText = 1` + `desiredCursorPosition`) onto ours, clear those flags on the previously active editbox so its `OnUpdate` doesn't also run a SetText.

Net effect: `SetText` runs exactly once per `OpenChat`, on our editbox, on the next frame. No extra slashes from explicit calls layered on top of `OnChar`.

## 010 — Fix: pressing "/" after /reload entered "//"

The v007 dedupe (only `SetText` when current text differs from target) wasn't fully covering Blizzard's deferred-text path. `ChatFrameUtil.OpenChat` stores `editbox.text = "/"` and `editbox.setText = 1`, then `ChatFrameEditBoxMixin:OnUpdate` applies the SetText on the next frame. Our hook ran synchronously and set the text immediately; on the next frame the `setText=1` path then ran `SetText(self.text)` *again*, and in some cursor states that produced "//".

Fix: clear `editbox.setText` and `editbox.text` on every BazChat editbox inside our `OpenChat` hook before applying our `SetText`. The deferred `OnUpdate` path can no longer fire a second SetText behind our back. We apply the text exactly once and own the result. Cursor position set to the end of the text so the user types where expected.

## 009 — Fix: UP arrow brought back the prefixed form ("/say hi") instead of raw input ("hi")

v008 added an `OnEnterPressed` pre-hook that captures the editbox's raw text before Blizzard's handler clears it. That alone is correct — but the pre-existing `AddHistoryLine` hook was still also capturing the *prefixed* form Blizzard's chat path passes ("/say hi" for a plain "hi" sent in say mode), so each user send produced two history entries: the raw text first, then the prefixed form. UP brought back the prefixed form (last entry).

Removed the `AddHistoryLine` hook entirely. The `OnEnterPressed` pre-hook captures slash commands too (the editbox text is "/dance" before Blizzard parses it), so we don't lose any capture path. UP now brings back exactly what the user typed.

## 008 — Fix: typed-input history not capturing new messages

Up-arrow chat history was loading saved entries from prior sessions but failing to add new messages typed in the current session. Existing capture went through three hooks (`C_ChatInfo.SendChatMessage`, legacy `SendChatMessage`, and per-editbox `AddHistoryLine`); recent Blizzard refactoring of the `ChatFrameEditBox` mixin tree appears to have moved methods around so that `hooksecurefunc` on the editbox instance silently no-ops in some cases.

Added a guaranteed pre-send capture in `History:Apply`: wrap the editbox's `OnEnterPressed` script so we read `self:GetText()` *before* Blizzard's handler clears it, then defer to the original. Idempotent (`_bcEnterHooked` flag) so it doesn't stack across re-applies. The other three hooks stay in place; `Add()` already de-dupes consecutive identical entries so multiple paths firing for the same message is harmless.

## 003 — Unified popup primitive

Replaced BazChat's two hand-rolled `StaticPopupDialogs` confirms with the new `BazCore:Confirm` primitive (BazCore v089). Both popups now match the rest of the BazCore UI — same fonts, buttons, backdrop — instead of inheriting Blizzard's default StaticPopup styling, which looked out of place sitting on top of a BazChat window.

- **Delete tab confirm** — right-click → Delete on any tab beyond General now uses the unified popup with a destructive (red) "Delete" button
- **Reset tabs confirm** — Tabs page → "Reset Tabs to Defaults" panic button uses the same primitive with a destructive "Reset" button

Requires BazCore 089+.

## 002 — Default settings tuned

Tuned the out-of-the-box defaults so the addon looks polished on first install rather than feeling like a wireframe. New users (and anyone who runs `/bc reset`) get:

- **`timestamps.format`** — `%I:%M %p` (12-hour AM/PM, no seconds) instead of `%H:%M:%S`
- **`windows[*].bgAlpha`** — `0.75` instead of `1.0` (slightly translucent so the world shows through behind the chat)
- **`windows[*].messageSpacing`** — `3` px instead of `0` (subtle inter-line gap for readability)
- **`windows[*].chromeFadeMode`** — `"always"` instead of `"off"` (unified bg+tabs visibility, both pinned to always-visible)

Existing users keep their current settings — these only apply to fresh installs or explicit resets.

## 001 — Initial release

Modern chat replacement for the Baz Suite, built on Blizzard's chat primitives — `ScrollingMessageFrame`, `ChatFrameMixin`, `ChatFrameEditBoxTemplate`, `TabSystemTemplate`. BazChat hides Blizzard's default chat windows and creates its own, owning the lifecycle, tabs, channel filtering, fade modes, persistence, and timestamp rendering end-to-end while preserving the standard message formatter, hyperlinks, edit-box history, BN whisper routing, and combat log.

### Tabs

- Default set: General, Guild, Trade, Log, plus a `+` button to create more
- Right-click any tab for the channel + rename + delete popup
- Hold-2s drag to reorder; order persists across `/reload`
- BazCore options page for tab management (rename, delete, edit channels, auto-show)
- Auto-show modes: Always, In a city, In a party, In a raid, In combat, In a battleground/arena, In a dungeon/raid

### Channel filtering

- Per-tab toggles for every chat category and every currently-joined channel
- 2-column popup with color-coded category labels
- Per-message channel-colored vertical gutter bar — green for guild, pink for whispers, yellow for system, custom-channel colors honored
- Bar colors update live when channel colors change via Blizzard's `/chat` config
- Channel notice rendering (Joined/Left/Changed Channel)
- Guild MOTD recovery on `/reload` + relog
- Tradeskill spam filter suppresses other players' "X creates Y" proximity broadcasts

### Two-column timestamps

- Left gutter rendering with channel-color bar
- Format dropdown: 24-hour, 24-hour with seconds, 12-hour, 12-hour with seconds
- Hover any timestamp for the full-date tooltip
- Wrap-aware: continuations align with message body, not under the timestamp
- Replayed history preserves the original capture time

### Persistent history

- 500 lines per tab saved across `/reload` + relog (configurable 100-2000)
- End-of-history separator clearly bracketed before live messages
- Channel-color and r/g/b preserved per line so the gutter bar reproduces correctly

### Channel name shortening

- `[Guild] → [g]`, `[Party Leader] → [pl]`, etc.
- Strips numeric prefix and zone suffix from custom channels: `[1. Trade - Stormwind] → [Trade]`
- Both behaviors independently toggleable
- Defaults match Prat / Chatter

### Copy chat

- Per-frame icon at the top-right corner of every chat window
- Last 500 visible lines pre-selected for `Ctrl+A` / `Ctrl+C`
- Color codes stripped for clean paste

### Auto-hide modes

- Per-element visibility (background, tabs, scrollbar): Always / On hover / On scroll / Never
- Unified background+tabs override

### Edit Mode integration

- Native `RegisterEditModeFrame` integration via BazCore
- Inline settings popup for opacity, scale, visibility modes
- Position nudge for pixel-precise placement

### Typed message history

- Up/Down arrows in the edit box cycle previous messages
- Persists across `/reload` and relog
- Captured at `C_ChatInfo.SendChatMessage`

### Slash commands

- `/bazchat` or `/bc` — open settings
- `/bc copy` — copy active tab
- `/bc clear` or `/clearchat` or `/cc` — clear active tab + history
- `/bc toggle` — master on/off
- `/bc reset` — wipe all settings

### Architecture

- Path B replica: Blizzard's default chat hidden, BazChat owns the windows from scratch
- `ChatFrameMixin` layered onto our frames so the formatter works natively
- `DEFAULT_CHAT_FRAME` repointed to BazChat's General tab
- Standard chat dispatch and filter pipeline preserved — the standard hooks the game exposes for chat customization continue to work normally
- Built on the BazCore SettingsSpec API: one source of truth feeds both the Options page and the Edit Mode popup
