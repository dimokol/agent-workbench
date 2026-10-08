# context-nudge

A one-line nudge when a session's context passes 250k, 400k and 600k tokens, and after an hour idle at 150k or more, so you can compact or start fresh.

## Install

    claude plugin marketplace add dimokol/agent-workbench
    claude plugin install context-nudge@dimokol

Without the plugin system: add `hooks/context-nudge.sh` as a `UserPromptSubmit` hook in `settings.json`, with options in `env`.

Each message shows once per threshold per session, goes to you (not the model), and never blocks the prompt. It re-arms when you `/compact` or `/clear` and the context shrinks.

## Config

Order: plugin option, then env var, then default. On a model with a 200k-token context the default sizes never fire, so set `size_thresholds_k` (env `CONTEXT_NUDGE_SIZE_THRESHOLDS_K`) lower, for example to `100,150`.

| Option | Env var | Default | What it does |
| --- | --- | --- | --- |
| `size_thresholds_k` | `CONTEXT_NUDGE_SIZE_THRESHOLDS_K` | `250,400,600` | Sizes in thousands of tokens |
| `idle_minutes` | `CONTEXT_NUDGE_IDLE_MINUTES` | 60 | Pause that triggers the idle nudge |
| `idle_min_context_k` | `CONTEXT_NUDGE_IDLE_MIN_CONTEXT_K` | 150 | Smaller sessions skip the idle nudge |

## Turn it off

    claude plugin disable context-nudge@dimokol

## Requirements

`python3` 3.7 or newer (without it the hook allows the prompt and says so once per session). State lives in `$CLAUDE_PLUGIN_DATA/state` or `~/.cache/context-nudge`.
