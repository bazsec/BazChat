# BazChat Changelog

## 030 — User guide refresh

The in-game User Manual page got a top-down rewrite. The "Architecture"
page is gone (it was developer notes that didn't belong in a player
manual). New pages cover the Combat Log tab, the Up/Down chat-input
history, and Profiles. The Welcome page lists current features cleanly
and the Slash Commands table is up to date.

## 029 — Guild MOTD on /reload, for real this time

v028 deferred the initial MOTD render until all chat windows existed,
which fixed one timing bug — but on /reload the guild data sometimes
takes a beat to settle, so a one-shot query came back empty and nothing
showed up. v029 asks the server for a fresh guild refresh and polls for
a few seconds as a fallback, so the MOTD lands as soon as the data is
there.

## 028 — Guild MOTD now shows on /reload again

Reloading no longer hides the Guild Message of the Day. Cold logins still
show it once, exactly when the server pushes it.

## 027 — Internal fix toward MOTD reliability

Fixed an internal timing bug that caused the Guild MOTD to silently skip
on /reload. (Superseded by v028 which actually finishes the job.)

## 026 — Guild MOTD no longer prints twice

The MOTD line could double-print after a /reload because of an old
listener frame sticking around from the previous session. Cleaned up so
exactly one MOTD shows per login.

## 025 — Up-arrow now recalls your most recent message first

Pressing Up in the chat box used to skip your last message and jump to
the second-to-last. Fixed — Up always pulls in the line you just typed.

## 024 — Tab clicks no longer flash the chat background off and on

Switching tabs while the chat fade was on briefly hid the background and
faded it back in. The tab strip is now treated as part of the chat for
hover purposes, so clicks don't trip the fade.

## 023 — Fade respects the tab strip

Hovering or clicking a tab keeps the chat background visible — no more
fading out the moment your cursor leaves the chat lines but stays on the
tabs.

## 022 — Combat Log tab follow-ups

Resizing the chat window no longer pushes the combat log filter buttons
back over the tabs. Opening Edit Mode no longer errors on the Log tab.

## 021 — Combat Log tab keeps the chat panel full-size

The Log tab's background and chrome stay the same size as every other
tab — only the text area is inset for the filter buttons row.

## 020 — Combat Log tab anchored to the right place

Fix for the Log tab stretching across the whole screen on /reload.

## 019 — Combat Log lives inside BazChat now

Blizzard's combat log filter buttons (My Actions, What Happened to Me,
Additional Filters) are pulled into the BazChat Log tab, so they line up
with the chat window instead of floating on Blizzard's hidden default
chat frame.

## 018 — Welcome line moved to BazCore

BazChat no longer prints its own load message; BazCore now prints a
single combined "Baz Suite loaded" line listing every Baz addon.

## 017 — Guild MOTD on /reload (initial attempt)

First pass at restoring the Guild MOTD on /reload. Worked for live
changes during a session but had a duplicate-print bug on cold login —
fixed in 026.

## 016 — Slash-command parsing fix

Typing `/something` in chat no longer turned into `//something` after a
/reload.

## 015 — Tab drag-to-reorder

Hold a chat tab for half a second to drag it into a new position. Order
persists across /reload.

## 014 — Per-message Up/Down history

Up and Down arrows in the chat box scroll through your typed-message
history — not just the last message you sent.

## 013 — Chat history persists across /reload

Lines you've already seen stay in the chat window after /reload instead
of starting from a blank scrollback.

## 012 — Tabs page in Settings

A Tabs subcategory was added under BazChat in Settings so you can rename,
add, and delete tabs from one place instead of right-clicking each one.

## 011 — Right-click channel popup per tab

Right-clicking the chat tab opens a popup that lets you toggle which
channels (Guild, Trade, Whisper, etc.) show in that tab.

## 010 — Modern tabs

The default Blizzard chat tabs are replaced with a single TabSystem strip
that matches the rest of the Baz Suite UI.

## 009 — Auto-hide for scrollbar and tab strip

Scrollbar and tab strip fade in only when you mouse over the chat,
matching the chat-content fade behaviour.

## 008 — Chat chrome (NineSlice background)

The chat windows now have a proper backdrop and border that matches
Blizzard's modern chat UI — no more transparent text floating in space.

## 007 — Replica chat windows go live

BazChat now owns the chat windows end-to-end (Replica path) instead of
adding overlays to Blizzard's default frames. This is the foundation
every later feature builds on.

## 006 and earlier

Earlier versions covered initial setup, slash commands, and the module
scaffold that v007's replica replaced.
