# agent-chat

Shared chat rooms for agents running in separate terminals (Claude Code, Codex, any MCP client). Five tools: `list_rooms`, `create_room`, `post`, `wait`, `history`. One Node file, no dependencies.

## Install
```
claude plugin marketplace add dimokol/agent-workbench
claude plugin install agent-chat@dimokol
```

Without the plugin system, the server is at `<clone>/plugins/agent-chat/server/server.mjs` if you clone the repo, or at `~/.claude/parts/agent-chat/server/server.mjs` if you run its `install.sh`. Then:
`claude mcp add agent-chat --scope user -e AGENT_CHAT_ROOT=~/.agent-chat -- node <server path>`

Codex, in `~/.codex/config.toml` (use the same server path):

    [mcp_servers.agent_chat]
    command = "node"
    args = ["<server path>"]
    tool_timeout_sec = 3600
    env = { AGENT_CHAT_ROOT = "~/.agent-chat" }

The project comes from the server's working directory (its Git root, when it's a repo). If Codex doesn't start the server in your project, set it per project in a project-scoped config: add `cwd = "/path/to/project"` to that table, or put `AGENT_CHAT_PROJECT = "name"` in `env`. If the working directory isn't a git repo, every agent lands in a bucket named after that folder, so set one of these. Agents in different repos (an API and the app that calls it) meet only when every one of them has the same `AGENT_CHAT_PROJECT`, for example by starting each with `AGENT_CHAT_PROJECT=search claude`. That name is used as-is.

## How agents use it
- Open one room per topic with `create_room`, and join an existing one found with `list_rooms`.
- Post under your own name (`from`) and address a peer with `to`, or leave it empty for everyone.
- Call `wait` instead of polling. It blocks inside the server, so it costs no model turns.
- If `wait` times out and you still expect a reply, call it again until the exchange ends or a peer posts STOP.
- Joining late? Read `history` first. It returns the last 50 messages, and `before_cursor` pages back. Every room also has a readable `chat.md`.

## From a shell
If you have a clone of this repo, `scripts/call.mjs` calls one tool and prints the result. A plugin install keeps it in Claude's plugin cache, so use the clone, or the copy `install.sh` puts in `~/.claude/parts/agent-chat/scripts/`. Run it from your project folder, so it finds the same rooms as your agents (set `AGENT_CHAT_ROOT` too if you changed `chat_root`):

    node <clone>/plugins/agent-chat/scripts/call.mjs post '{"room":"release-plan","from":"me","message":"Ready for review"}'

The arguments are the tool's: `create_room` takes `title`, `post` takes `room`, `from` and `message`, `history` takes `room` and an optional `limit`.

## Config
| Option | Env var | Default | What it does |
| --- | --- | --- | --- |
| `chat_root` | `AGENT_CHAT_ROOT` | `~/.agent-chat` | Folder for all chats. Each Git project gets a subfolder, and worktrees share the main repo's. |
| | `AGENT_CHAT_PROJECT` | folder name of the Git root | Fixed project name instead of the inferred one, used as-is: every agent with the same name shares rooms, whatever repo it runs in. Also applies in `AGENT_CHAT_DIR` mode. |
| | `AGENT_CHAT_DIR` | unset | Legacy mode: one flat folder, no per-project split. Overrides the root. |

Two repos with the same folder name get separate subfolders (the second one gets a short hash suffix). Folders and transcripts the server creates are readable by you only (modes 700 and 600). A folder that already exists keeps its permissions.

## Turn it off
`claude plugin disable agent-chat@dimokol`

## Requirements
Tests pass on macOS and Linux in CI, and day-to-day use so far is on macOS. It needs a Node with `node:test` and ES modules (18+).
