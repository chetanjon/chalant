# Chalant 1.9.0

Chalant is back to being an island. Your day, clipboard, shelf, notes, focus and music, with nothing watching over your shoulder. The agent-sessions surface and the Chat tab are gone in this release.

## What left

- **The Sessions tab and room.** The list of running agents, the approval and question cards, the composer, and the "came to rest" announcements.
- **The Sessions settings page.** The arm buttons, the rules, the standing permissions view, and the Cursor and Codex cards.
- **The Chat tab.** The small built-in browser onto your own Claude, ChatGPT or Gemini account.
- Everything that pointed at them: the tabs, their global shortcuts, the glance badge for running agents, and the settings rows.

Nothing else changed. The ask bar, voice, reminders, calendar, timers, ambience and music are exactly as they were.

## Read this if you had armed the hooks

- **Your agents lose nothing but the cards.** With nowhere to show a card, Chalant now answers every held hook instantly with no opinion, so every prompt lands in your terminal exactly as it would without Chalant. No call ever waits on this app.
- **You can take the hook entries out.** They are harmless now, but if you want a clean file, remove the Chalant entries from `~/.claude/settings.json` (they point at `127.0.0.1:4242` or at `chalant-hook`).
- **Standing permissions still answer.** Grants you made from earlier approval cards keep auto-allowing at the wire. If you would rather they did not, delete `~/Library/Application Support/Chalant/policy.json`.
- **The grant migration still runs, and it is one-way.** "Always allow" rules made in 1.8.x move into Chalant's own grant store on first launch. A later downgrade to 1.8.2 cannot read them back.

## Under the hood

- The whole surface is dark-shipped, not deleted: the engines and their tests are intact underneath, so it can return whole if it earns its place back.
- A second Chalant (a dev build, the test runner) can no longer rewrite the live one's port or hooks and strand them on exit.
- 587 tests, up from 556.
