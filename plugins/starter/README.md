# starter

Installs the four parts most people want first: git-guardrails, machine-pressure,
worktree-hygiene and agent-chat. It has no code of its own.

## Install
```
claude plugin marketplace add dimokol/agent-workbench
claude plugin install starter@dimokol
```

Without the plugin system: `bash install.sh starter` from a clone of this repo installs the same four parts.

## Turn it off
Disable starter first, then the parts you don't want, for example:
```
claude plugin disable starter@dimokol
claude plugin disable agent-chat@dimokol
```
