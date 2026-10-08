---
name: setup-audit
description: Weekly audit of your Claude Code setup. Use when asked to "audit my setup", "weekly audit", "what's new in Claude Code", "check config drift", or "run my tripwires". Proposes changes, never applies them.
---

# Setup audit

Reads what changed in Claude Code and its community since the last run, runs your own drift checks, and appends a short log. Modes: `weekly` (default when no argument is given) and `deep`.

## Rules

- Propose, never apply. Write only inside `$AUDIT`. Never edit settings, CLAUDE.md files, hooks or memory during a run. Changes wait for the user's explicit go.
- Report deltas only. If nothing changed, say so in one line.
- Mark anything you didn't check against a primary source or a file on disk as unverified.

## Config

- `audit_dir`, default `~/.setup-audit`. Read it from the plugin option `${user_config.audit_dir}`, else the `audit_dir: <path>` line in an `## setup-audit config` block in the project's CLAUDE.md, else the default. A value that still reads as a literal `${...}` or is blank means unset. Expand a leading `~` to the home folder. Never put `${...}` inside a shell command. Call the result `$AUDIT` below.

## First run

If `$AUDIT` doesn't exist, create it and copy in `templates/weekly-log.md`, `templates/tripwires.md` and `templates/awesome-snapshot.md` from this skill's folder. Tell the user the path and that `tripwires.md` is theirs to edit. Use `claude --version` as the changelog anchor.

## Weekly pass

1. Read the newest section of `$AUDIT/weekly-log.md`. Note its date and its `anchor:` version.
2. Fetch `https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md`. It has versions and no dates, so list the entries newer than the anchor. Flag anything touching hooks, skills, memory, settings schema, scheduled tasks, notifications, or auth and profiles. Record the new top version as this run's anchor.
3. Fetch `https://raw.githubusercontent.com/hesreallyhim/awesome-claude-code/main/README.md` (raw, because the rendered page truncates; use `curl` if the fetch tool clips it). Compare the sections listed in `$AUDIT/awesome-snapshot.md` against the snapshot. Note additions and removals, then overwrite the snapshot. If a category disappears, track its closest successor and note the rename.
4. Run every tripwire in `$AUDIT/tripwires.md` with read-only commands (`ls`, `grep`, `wc`, `diff`). A tripwire that errors is reported as errored, not as passed.
5. Append a `### YYYY-MM-DD` section to `$AUDIT/weekly-log.md` using the template's fields: anchor, changelog items that matter, ecosystem changes, a one- to three-line "worth adopting?" verdict, tripwires that fired. With zero deltas and zero tripwires, append one "no deltas" line and the anchor.
6. Reply with the section you appended, verdict first. Offer to apply any proposal, one at a time.

## Deep pass (optional)

Run only when asked for `deep`, and confirm first if the session is about something else. It is heavy.

1. Do the weekly pass.
2. Read-only study: one pass per area you actively maintain (each project, the global config folders, scheduled jobs, everything else). Reuse the headings of earlier notes in `$AUDIT/findings/` so runs stay comparable.
3. Research current best practice for the tool from several sources. Cross-check claims before trusting them. A single post saying "everyone uses X" is not evidence.
4. Reconcile `$AUDIT/findings/` and `$AUDIT/recommendations.md`: mark old items RESOLVED with a date instead of deleting them, add new ones, re-rank the list.
5. Report the top five changes since the last deep pass, new recommendations, and the resolved count.

## Scheduling (optional)

To stop relying on memory, run the weekly pass from `cron`, a systemd timer, a LaunchAgent, or Claude Code's scheduled tasks. Limit the job's write access to `$AUDIT` so a bad run can't touch real config.

## Common mistakes

- Running deep when no argument was given. No argument means weekly.
- Fixing config "while you're there". The audit writes only under `$AUDIT`.
- Deleting old recommendations in deep mode. Mark them RESOLVED.
- Quoting adoption or star counts without checking the source's own page or API.
