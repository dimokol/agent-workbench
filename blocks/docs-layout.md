## Docs layout

```text
docs/
  specs/                what to build and why, written before the code
  plans/                how to build it, step by step
  handoffs/
    not-yet-handed/     written, nobody has started it
    handed/             picked up, and kept here once finished
```

- A spec covers intent, scope, constraints and open questions. Write it before the code, so
  someone can check the idea before anything gets built.
- A plan lists the steps to implement a spec, in order, and links the spec instead of repeating
  it. Check steps off as they land, so anyone opening it partway through sees how far it got.
- Name docs `YYYY-MM-DD-<topic>.md`. A listing then sorts by date, and the date shows how stale
  a doc might be.
- Handoff names add a purpose suffix: `-RESUME` (pick up where it stopped), `-REMAINING` (what's
  left of a larger effort) or `-AFTER-<milestone>` (the next step once something else lands).
  For example `2026-06-10-billing-migration-REMAINING.md`.

## Handoffs

Write a handoff when work spans more than one session and the next session won't have this
one's context: a migration paused partway, a branch blocked on something external, a decision
that took real back-and-forth. Skip it when the work finishes in one sitting, or when the task
tracker or PR description already says what's left and the resume steps need no explaining.

A handoff holds the resume detail that's too long for a task description and too tied to the
moment to belong in the spec or plan. Someone opening it cold should need nothing else. Write it
in plain language, without shorthand or ticket codes that only made sense in the original session.

New handoffs start from `docs/handoffs/TEMPLATE.md` (session, state, next step, open loops, links).

- The session that picks up a handoff moves it from `not-yet-handed/` to `handed/` as its first
  step. Then `not-yet-handed/` lists only open work, and nobody starts the same thing twice.
- Update the handoff when the state changes enough that the next reader would be misled.
- Commit handoffs. They're meant to outlive the session that wrote them.
- Don't commit an agent's scratch files (temp notes, file dumps, the working-memory files some
  agent tools keep). Keep them in one folder, for example `.scratch/`, and add it to
  `.gitignore`. If a future session needs a file to resume, it belongs under `docs/`. If it only
  helped the current agent keep track of itself, leave it there.

## Editing guide

Keep a table in this file, or in `docs/editing-guide.md` linked from here, that maps each thing
people change often to the one file or token that owns it. Phrase each row as an intent, so
someone new to the code can find theirs.

| I want to change... | Edit | Notes |
|---|---|---|
| The primary color | `--color-primary` in the design tokens file | Components read the token. Never hardcode the hex value. |
| Body text size | `--font-size-body` in the design tokens file | One token sets every paragraph and list. |
| A section's copy | that section's data file, for example `data/<section>.ts` | Copy lives outside the component, so a copy edit never touches component code. |

- When someone asks where to change something, check the table before searching the code.
- A value set in several places gets a row only after it's consolidated into one source.
- A new shared source gets its row in the same commit.
- If a row and the code disagree, fix whichever one is wrong in the same change. A stale row
  sends people to the wrong file.
