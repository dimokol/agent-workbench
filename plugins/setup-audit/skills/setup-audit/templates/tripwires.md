# Tripwires

Your own drift checks. The audit runs each one with read-only commands and reports the ones that
fire. Edit, delete or add. Each tripwire has a name, a command, and the result that counts as a pass.
Replace the example paths with yours.

## Hook scripts still exist

A hook whose script moved or was deleted errors on every matching tool call.
Command (bash): `jq -r '.hooks[]?[]?.hooks[]?.command' ~/.claude/settings.json | awk '{print $1}' | grep '^[~/]' | while read -r f; do [ -e "${f/#\~/$HOME}" ] || echo "missing: $f"; done`
Pass: no output.

## Instruction file size

Claude Code warns when a CLAUDE.md passes 40,000 characters.
Command: `wc -m ~/.claude/CLAUDE.md ./CLAUDE.md`
Pass: every count is under 40000.

## Stray settings backups

Command: `ls -a ~/.claude | grep -E '\.(bak|backup|orig)$'`
Pass: at most the one backup you keep on purpose.

## Memory index against disk

Every file listed in a memory index should exist, and every memory file should be listed.
Command (bash): `diff <(grep -o '([^)]*\.md)' <memory-dir>/MEMORY.md | tr -d '()' | sort) <(ls <memory-dir> | grep -v '^MEMORY.md$' | sort)`
Pass: both lists match.

## Version claims against the source

A version written in CLAUDE.md should match the one in `package.json`.
Command: `grep -i version ./CLAUDE.md; grep '"version"' ./package.json`
Pass: the numbers agree.

## Secrets in common folders

Command: `grep -rlE 'sk-[A-Za-z0-9_-]{20,}' ~/Downloads ~/projects 2>/dev/null`
Pass: no output. Report file names only, never the matching text.

## Expired cron entries

Command: `crontab -l 2>/dev/null | grep -i 'remove after'`
Pass: no entry carries a date in the past.
