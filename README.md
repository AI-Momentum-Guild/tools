# AI Momentum Tools

The public Claude Code marketplace of the AI Momentum Guild (marketplace name `ai-momentum`). It holds Free tools only: anyone can add it and install them.

```
claude plugin marketplace add AI-Momentum-Guild/tools
```

## Windows: personal setup for Claude Code

`setup.ps1` installs Claude Code for you and adds the AI Momentum marketplaces your GitHub account can reach. No admin rights needed. In PowerShell:

```powershell
irm https://raw.githubusercontent.com/AI-Momentum-Guild/tools/main/setup.ps1 | iex
```

Read it first if you like; it says what it does at the top. To see what it would do without changing anything, add `-WhatIf` using the longer form in its help.

This repository is generated. Each plugin under `plugins/` is published from the AI Momentum Guild's source by its build, and `.claude-plugin/marketplace.json` is regenerated on every publish, so changes made here by hand are overwritten.
