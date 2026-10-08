# machine-pressure

A gate refuses a second e2e or docker run, and any heavy command while CPU, RAM, swap or disk is RED. A probe script feeds your statusline.

## Install

    claude plugin marketplace add dimokol/agent-workbench
    claude plugin install machine-pressure@dimokol

Without the plugin system: add `hooks/heavy-op-gate.sh` as a `PreToolUse` hook (matcher `Bash`) in `settings.json`.

## Statusline

A plugin can't set the statusline, so copy the probe, then point `statusLine` at it:

    mkdir -p ~/.claude/scripts && curl -fsSL https://raw.githubusercontent.com/dimokol/agent-workbench/main/plugins/machine-pressure/scripts/pressure.sh -o ~/.claude/scripts/pressure.sh && chmod +x ~/.claude/scripts/pressure.sh
    { "statusLine": { "type": "command", "command": "~/.claude/scripts/pressure.sh --statusline" } }

Other modes: `--json`, `--field cpu|ram|swap|load|disk|level`. Level is OK, AMBER, RED, or UNKNOWN when nothing can be read (never RED). Readings are cached 4 seconds.

### ccstatusline indicators
[ccstatusline](https://www.npmjs.com/package/ccstatusline) can show one colored widget per signal. Add custom-command widgets to a line in `~/.config/ccstatusline/settings.json` (all six: `examples/ccstatusline.json`). Each is `{ "type": "custom-command", "commandPath": "~/.claude/scripts/pressure.sh --field ram", "preserveColors": true, "timeout": 2500 }`. If a widget stays empty, write the full home path instead of `~`.

## Config

| Option | Env var | Default | What it does |
| --- | --- | --- | --- |
| `cpu_amber`, `cpu_red` | `MACHINE_PRESSURE_CPU_AMBER`, `_CPU_RED` | 85, 97 | CPU % of all cores |
| `ram_amber`, `ram_red` | `MACHINE_PRESSURE_RAM_AMBER`, `_RAM_RED` | 85, 93 | RAM in use, % |
| `swap_amber`, `swap_red` | `MACHINE_PRESSURE_SWAP_AMBER`, `_SWAP_RED` | 70, 90 | Swap in use, % |
| `disk_amber_gb`, `disk_red_gb` | `MACHINE_PRESSURE_DISK_AMBER_GB`, `_DISK_RED_GB` | 20, 10 | Free GB on `/` |
| `load_amber_x`, `load_red_x` | `MACHINE_PRESSURE_LOAD_AMBER_X`, `_LOAD_RED_X` | 1.5, 3 | 1-min load, times core count |
| `max_parallel_heavy` | `MACHINE_PRESSURE_MAX_PARALLEL_HEAVY` | 1 | Concurrent e2e or docker runs |
| `extra_heavy_patterns` | `MACHINE_PRESSURE_EXTRA_HEAVY_PATTERNS` | none | Regexes (comma separated in the env var) for more gated commands |

Each setting comes from the plugin option, then the env var (`settings.json` `env`; the statusline script reads only that), then the default. Gated: installs, builds and test runners (npm, pnpm, yarn, bun, workspace forms, pytest, cargo, go, turbo, make, mvn, gradle), e2e (playwright, cypress, `test:e2e*`), docker run/build/compose up. Anything else: `extra_heavy_patterns`. Commands that free memory (`docker compose down`, `e2e:down`) and quoted text never match. To run one command anyway, start it with `PRESSURE_ALLOW=1 `. An attached long-running `docker run` (an `-it` shell) holds the docker slot until it exits.

## Turn it off

    claude plugin disable machine-pressure@dimokol

## Requirements

Tested on macOS. The Linux code paths exist but haven't been run on Linux yet. Needs `sh`, `awk`, and `jq` for the gate (without jq it allows everything and says so once). Other systems report UNKNOWN. Where `ps` lacks `-A -o pid=,ppid=,command=` (busybox), the parallel cap does nothing.
