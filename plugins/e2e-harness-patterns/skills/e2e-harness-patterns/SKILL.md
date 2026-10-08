---
name: e2e-harness-patterns
description: Patterns for a local e2e test harness that parallel agents can share. Use when asked to "build an e2e harness", "make e2e parallel-safe", "run Playwright per worktree", "fix e2e port collisions" or "run only affected specs".
---

# e2e harness patterns

Patterns for a local end-to-end harness that several agents (one per git worktree) can run at the same time without touching each other or your dev server. Examples use Node and Playwright. The ideas work with any runner.

Use it to design or audit a harness. It doesn't help with choosing a runner or writing single specs.

## Config

- `max_stacks`, default `2`. Read it from the plugin option `${user_config.max_stacks}`, else the `max_stacks: <n>` line in an `## e2e-harness-patterns config` block in the project's CLAUDE.md, else the default. A value that still reads as a literal `${...}` or is blank means unset. Never put `${...}` inside a shell command; substitute the number first.

## 1. One stack per worktree, as host processes

Run the services (API, web app, workers) as local processes started by one supervisor script. Docker is the fallback (pattern 7), because image builds and a heavy VM are what make a harness slow on a laptop.

The supervisor has these commands: `up`, `reseed`, `down`, `status`, and `run <specs>`.

- Keep all state under one gitignored folder in the worktree (for example `.e2e-stack/`): pid files, logs, the database files, Playwright output. Writes outside it can trigger dev-server rebuilds mid-spec. Also exclude it from the dev server's file watcher.
- `up` is idempotent. If the stack for this worktree is healthy, reuse it (this should be fast).
- Start services in dependency order. Wait for each health check before starting the next. Never use `sleep`.
- `down` kills the whole process group, including child processes such as `next start`. Check with `status` that nothing is left.
- Give each service its own data store, for example an in-process or per-stack database named after the stack id. Never point the stack at the dev database.
- The backend needs one narrow entry point for e2e (a script or flag) that accepts port, database URL, run id and allowed origin, and refuses to start if the database URL looks like a shared or remote one.

## 2. Ports from the worktree path

Collisions come from fixed ports. Derive them instead.

1. Hash the absolute worktree path to a decimal number with `printf '%s' "$PWD" | cksum | cut -d' ' -f1`. Compute the slot as `hash % 200` and the port as `base + slot * 10 + service_index`. (`shasum` prints hex, which shell arithmetic can't take as is, so use `cksum`.)
2. Probe the derived port. If it's taken by something that isn't this stack's pid file, step to the next slot (wrap to 0 after the last) and write the chosen ports into `.e2e-stack/ports.env`.
3. Export them as `E2E_API_URL`, `E2E_APP_URL` and so on. Specs read only these variables.
4. Listen on both IPv4 and IPv6, and probe `::` as well as `127.0.0.1`. A stale listener on one family looks like a healthy port.

## 3. Cap concurrent stacks

Several agents starting stacks at once will exhaust a laptop's memory.

- Allow at most `max_stacks` live stacks. Use numbered slots `slot-1` to `slot-N` under a shared `e2e-slots` folder in `$TMPDIR` (else `/tmp`).
- Take a slot with `mkdir <folder>/slot-<i>` (atomic and portable), trying `i` from 1 to N, and write the stack's pid into `slot-<i>/pid`.
- If `mkdir` fails, read that slot's pid. An empty or missing pid file means another stack is mid-take (between `mkdir` and the pid write), so leave the slot alone and retry. Only a non-empty pid for which `kill -0 <pid>` fails marks a dead owner: remove the slot and retry it.
- When all N slots are busy, wait and retry every few hundred milliseconds. After a timeout, refuse to start and name the pids holding slots.
- Release the slot in `down` and in an `EXIT` trap.

## 4. Seeded data per stack

- One seed script, run by `up` and by `reseed`. It resets the stack's database and inserts fixtures. A reseed should be fast enough that specs can reset between files.
- Fixture ids and names live in one shared constants module that specs import. No inline ids in specs.
- Give each parallel spec its own entities (per-spec fixtures) when specs mutate data. Never wait with `waitForTimeout` for another spec to finish.
- Fixtures that depend on "today" need one timezone for the stack and the browser. Set it explicitly in both.
- Blank values in dotenv files count as set in some loaders. Remove the key instead of leaving it empty.

## 5. Playwright setup

- `baseURL` and API URLs come from the environment variables in pattern 2. No hard-coded ports.
- Skip the login screen in most specs. Prime storage state in global setup with a test-only session (a token endpoint that exists only when the e2e flag is on, or a fixture session in the seed). Never sign tokens with a production secret.
- Keep at least one spec that goes through the real login UI.
- Set `outputDir` to a folder under `.e2e-stack/`. Keep traces on first retry.
- Start with one worker. Add workers only after you've measured a full run and seen that data isolation holds.

## 6. Affected-only runs

Run the union of these three sets:

1. Specs changed in the diff (`git diff --name-only <base>...HEAD`, filtered to spec files).
2. Specs that import a changed file, directly or through the import graph (`playwright test --only-changed=<base>` does this).
3. Specs whose `// @covers <glob>` header matches a changed file. This catches specs that reach code only over the network, such as a GraphQL or REST resolver.

If nothing matches, decide from the diff. Docs, copy and config changes need no run. Behaviour changes with no matching spec need a new spec. Give the harness these scripts: `e2e:affected` (default for the inner loop), `e2e:full` (merge gate, run rarely), and `e2e:nostack` (run against a stack that is already up).

A run is worth starting for new features, logic changes and non-trivial fixes. Skip it for typo, comment and config edits. When unsure whether a spec is affected, leave it out and let the full run catch it.

## 7. Docker fallback mode

Use it when services can't run on the host (a database with no local build, a different OS). Select it with a flag such as `E2E_DOCKER=1`.

- Publish ports with `published: 0` and read the assigned port back with `docker compose port`, or reuse the derived ports from pattern 2.
- Name the compose project after the worktree hash so stacks don't share networks or volumes.
- Gate startup on container health checks.
- Tear down with `docker compose down -v` to drop volumes. Offer an opt-in `PRUNE_ON_EXIT=1` for build cache.
- Serialize image builds with a lock (`mkdir` on a lock folder) so parallel agents don't build the same image at once. Pattern 3's slot limit applies here too.

## 8. Keep the loop fast

- Measure before optimizing: stack up, reseed, reuse, affected run, full run. Write the numbers in the harness README.
- Leave the stack up between iterations (`KEEP_STACK=1`), then restart it every few hours. Long-lived stacks drift away from the seed.
- A PR review loop can call `e2e:affected` as its gate. The harness needs to boot itself, run and report an exit code, so the caller needs no knowledge of the stack layout.

## Checklist

- [ ] Stack per worktree, state under one gitignored folder, teardown kills child processes.
- [ ] Ports derived from the worktree path, collision-checked, exported as env vars.
- [ ] Slot limit (`max_stacks`) with atomic locking and stale-slot reaping.
- [ ] Health checks between services. No `sleep`.
- [ ] Seed and reseed scripts, shared fixture constants, one timezone.
- [ ] Storage-state login plus one real-login spec.
- [ ] Affected-only and full commands, `@covers` headers on specs that need them.
- [ ] Docker fallback documented, off by default.
- [ ] Timings recorded in the harness README.
