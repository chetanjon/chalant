# Evidence: showing Claude Code's own questions in the notch

Captured 2026-08-03 on this machine, by instrumenting `scripts/chalant-hook`
to append raw payloads behind an opt-in defaults key, then asking a real
`AskUserQuestion` and reading what arrived.

## The hook payload carries nothing renderable

One `Notification` event, in full:

```
hook_event_name  : Notification
notification_type: permission_prompt
message          : Claude needs your permission
session_id       : 53db8ee8-...
prompt_id        : cf1e37b6-...
transcript_path  : ~/.claude/projects/.../53db8ee8-....jsonl
cwd              : /Users/sriujjwal/github/chalant
```

**No question text. No options.** `message` is a fixed string. So a hook
alone cannot render the picker, and anything built on the assumption that it
could would have been wrong.

## The transcript carries all of it

The same question, pulled out of the tail of `transcript_path`:

```
tool_use name: AskUserQuestion
input.questions[0].header  : "Auto-open"
input.questions[0].question: "...should a question open the island by itself?"
input.questions[0].options : ["Yes, always open (Recommended)",
                              "Only when nothing else is open",
                              "Never, keep the current mark"]
```

`SessionDiscovery` already reads this file, already reads only the tail, and
already walks assistant `content` blocks looking for `tool_use`. Extracting
`AskUserQuestion`'s input is the same pass, one more case.

## So the division of labour is

- The **hook** says *a question just appeared*, and for which session. That
  is the timing signal, and it is all it can give.
- The **transcript** says *what the question is*. That is the content.

Neither alone is enough. Together they are exactly enough to render it.

## The limit, which the interface has to admit

**Answering in the notch cannot dismiss Claude Code's own prompt.** There is
no documented way to resolve an `AskUserQuestion` from outside the process,
and this is the same wall the messaging milestone hit: injection at a turn
boundary is supported, reaching into a running prompt is not.

So the notch can show the question and its options, which is most of the
value, since knowing what is being asked without switching windows is the
whole point. What it must not do is present buttons that look like they
answer it and then silently fail. Either:

- show it read-only and say the answer goes in the terminal, or
- let a tap queue the chosen text through the outbox, which is a real
  mechanism and arrives at the next turn boundary rather than resolving the
  prompt.

The second is more useful and more honest only if the wording says which of
the two it is doing. It must never look like the native picker while
behaving differently.

## Not established

- Whether `prompt_id` can be correlated to the specific `tool_use` block, so
  a stale question from earlier in the tail is never shown as current. The
  block's own id and position in file order are the fallback.
- Whether a question already answered leaves a marker in the transcript that
  distinguishes it from one still waiting. Without that, a just-answered
  question could linger in the island. This must be solved before shipping,
  since a question that stays after it is answered is worse than none.
