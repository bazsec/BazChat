# BazChat Changelog

## 002 — Stop the chat-event taint spam

Midnight's Blizzard chat code added a `HistoryKeeper` that holds
forbidden tables. Reading them while the call context is attributed
to an addon throws `attempted to index a table that cannot be
accessed while tainted`, which fired on every monster yell / chat
event we listened to.

Wraps the chat frame's `OnEvent` dispatch in `securecallfunction`
so BazChat's call attribution doesn't leak into Blizzard's downstream
secure work (`ChatHistory_GetAccessID`, `RemoveExtraSpaces`, etc.).

## 001 — Initial release

A modern chat replacement for the Baz Suite. Owns its chat windows
end-to-end — Blizzard's default chat is hidden, BazChat's frames
inherit ChatFrameMixin so the standard message formatter, hyperlinks,
edit-box history, BN whisper routing, and combat log all keep working.

### Features

- **Replica chat windows** with NineSlice chrome that matches the
  rest of the Baz Suite UI.
- **Multiple containers**. The main dock holds your tabs; any tab
  can be popped out into its own floating window. Popped windows are
  first-class — own tab strip, own "+" button to add tabs in place,
  own resize handle, own Edit Mode registration. Tabs migrate between
  containers via a "Move to" submenu on shift+right-click.
- **Per-tab channel filtering**. Right-click a tab → toggle which
  chat categories and joined channels appear there. Defaults match
  the Blizzard tab presets (Guild / Trade / Log).
- **Persistent history across `/reload` and relog**. Default 500
  lines per tab, configurable 100 – 2000.
- **Two-column timestamps** with a channel-colored vertical bar per
  message (green for guild, pink for whispers, custom-channel colors
  honored from `ChatTypeInfo`).
- **Up/Down arrow** in the chat editbox cycles through your typed-
  message history. Survives `/reload`.
- **Auto-show modes per tab** — Always / In a city / In a party /
  In a raid / In combat / In a battleground / In a dungeon.
- **Drag-to-reorder tabs**. Hold a tab for two seconds and drag.
- **Lock toggle** per chat window. Unlocked: drag the dock from any
  empty area in the tab row, resize from the bottom-right grabber,
  no need to enter Edit Mode. Locked: chat is fixed in place.
- **Per-frame copy-chat icon** on the chrome's top-right opens
  BazCore's copy dialog.
- **Modern modifier-click context menu**. Shift+right-click a tab
  for Rename / Channels / Clear messages / Move to / Lock / Delete.

### Slash commands

- `/bc` or `/bazchat` — open the BazChat options page.
- `/bc lock` / `/bc unlock` — toggle the active chat window's lock.
- `/bc clear` — clear the active chat window and its persistent
  history.
- `/bc copy` or `/clearchat` / `/cc` — convenience aliases.
- `/bc restoredefaults` — restore deleted Guild / Trade / Log tabs.
- `/bc reset` — wipe BazChat's saved settings (asks for confirmation).
