# Paste-in blocks

Plain-text rules for an agent's instruction file. Global ones go in `~/.claude/CLAUDE.md` or
`~/.codex/AGENTS.md`, project ones in `CLAUDE.md` or `AGENTS.md`. Edit what doesn't fit first.

| Block | What it's for | Where it goes |
|---|---|---|
| [working-agreement](working-agreement.md) | When the agent asks and when it just acts, how it reports back, verifying before "done" | Global |
| [writing-tone](writing-tone.md) | Plain, human wording in replies, commits, PRs and docs | Global or project |
| [project-standards](project-standards.md) | Web app rules for latency, pagination, search, totals, shared values and UI checks | Project |
| [docs-layout](docs-layout.md) | Where specs, plans and handoffs live, and a "change X, edit Y" table | Project |
| [handoff-template](handoff-template.md) | The template docs-layout points to (filled copies go in `docs/handoffs/not-yet-handed/`) | Copy to `docs/handoffs/TEMPLATE.md` |
| [product-copy-voice](product-copy-voice.md) | A worked example of deriving a product's copy voice. Adapt it first | Project |

To fetch one: `curl -fsSL https://raw.githubusercontent.com/dimokol/agent-workbench/main/blocks/writing-tone.md -o writing-tone.md`, then edit it and paste it in.

Want a stricter rule? In working-agreement.md, replace the bullet that starts "For ordinary edits, a clear task request" (under "Ask before anything irreversible") with: require an explicit go in the latest message before every write, edit, delete or push.
