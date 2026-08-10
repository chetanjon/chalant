# Chalant 1.9.0

The island now answers everything through one held pipeline. The gate that holds a tool call, the permission prompt, an MCP server's question, and (new) Claude Code's own multiple-choice questions all arrive the same way: a hook suspended on Chalant's door until you decide, with the answer traveling back the moment you tap.

## Read this before updating

**1. Grant migration is one-way.** Your "Always allow" rules move from app preferences into Chalant's own grant store (policy.json) on first launch, and the old store is emptied. Grants made by 1.9.0 (including "always" and "everywhere" ones) cannot be read by 1.8.2. If you downgrade to 1.8.2 after running 1.9.0, your standing permissions are gone and every previously-always-allowed call asks again. Timed grants you made in 1.8.x survive the upgrade; only the downgrade loses state.

**2. Question cards and finished-row summaries now require the hooks to be armed.** Both used to work with nothing set up, by reading session transcripts off disk. Those free paths are removed: questions are now intercepted and genuinely answered through a hook (the old card could only queue a note for the next turn), and a finished row's summary now comes from the Stop hook's own payload instead of a transcript guess. The cost: with "Answer prompts and questions here" switched off, question cards do not appear and finished rows have no summary line. The switch is one button in Dashboard, Sessions, and once on it maintains itself.

**3. Legacy hook entries upgrade themselves on next launch.** If you armed "Hold for approval" on an earlier version, your settings.json carries a command-style hook that polled for its answer. The first launch of 1.9.0 replaces it, in the same file write, with the new http entry pointing at the live port. Your old settings file is copied aside first, like every write Chalant makes there. Nothing to do; noted here so a changed settings.json does not surprise you.

## New

- **Answer Claude Code's questions from the island.** When an agent asks a multiple-choice question (AskUserQuestion), the card now shows the real thing: every question in the bundle, numbered options with their descriptions, and a free-text field. Tapping an option answers the agent directly. Unanswered for 20 seconds, the question returns to the terminal picker exactly as before; "Answer in terminal" hands it back immediately.
- **The gate holds calls natively.** A held tool call is now one suspended request instead of a script polling once a second. The approval card counts down the hook's real timeout, answers land instantly, and a prompt settled elsewhere (terminal, phone) releases the card immediately.
- **One place for "don't ask again."** The Always allow button, the timed "Allow ... for" menu, and a new "Always, everywhere" option all write standing permissions to the same store, all shown and revocable under Dashboard, Sessions, Standing permissions. None of them can cover the always-ask list (sudo, force pushes, credentials, and kin).
- **Truthful pills.** An agent waiting on input and an agent that finished now get their own pills ("needs input" / "finished") instead of everything reading "wants you".
- **A wire tail for the curious.** `chalant tail` follows a live log of every hook event: timestamp, event, notification type, tool, and what Chalant answered.

## Fixed

- **Restarts and second instances can no longer strand your hooks.** Running two Chalants at once (the installed app beside a dev build, or the test runner) used to let the second one rewrite your hooks to a fallback port that died with it, leaving every hook failing with connection refused. A second instance now detects the live one and leaves your configuration alone; the unit-test host no longer starts the real app at all.
- Multi-select answers now deliver every picked option, not just the first.
- Removing the approval hook now works even if it shares a settings entry with another tool's hook.

## Under the hood

- The two continuation stores behind held prompts and held questions are one shared implementation with one tested discipline: resume exactly once, duplicates fall through, hangups and session-end release cleanly.
- The transcript scraper no longer parses questions or last messages out of session files, removing the parser most likely to break silently on a Claude Code format change.
- 580 tests, up from 556.
