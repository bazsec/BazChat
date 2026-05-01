# BazChat changelog

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
