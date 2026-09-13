# Workstation

The machine is a build system. Everything on it is one of eight kinds of thing, and each kind has one home.

```
C:\Unykorn\
  00_INBOX\        single landing zone; triage weekly; nothing lives here longer than a sprint
  10_PLATFORMS\    every git repository (portal, ldx-capitol, xrpl hooks, L1 engine, ERC-3643, tooling)
  20_CLIENTS\      active client and deal work, one folder per client
  30_DOCS\         developer docs as a git repo: architecture, ADRs, runbooks, playbooks, generated INDEX.md
  40_VAULTS\       hash-verified evidence vaults and their mirrors
  50_TOOLS\        local tooling, Ollama models, wrangler configs, a keys manifest (never the keys)
  60_MEDIA\        renders, video and audio masters, brand assets by project
  90_ARCHIVE\      cold storage in dated subfolders, never edited in place
```

Rules that keep it clean:

- A repository lives in `10_PLATFORMS` and nowhere else. Never inside OneDrive: syncing `.git` corrupts repos.
- OneDrive holds only what needs to be on other devices: vault mirrors and documents you open on the phone.
- Downloads is a buffer. The vault sweep and the inbox triage empty it.
- Build output is disposable. `node_modules`, `target`, `dist`, `.venv` are never archived or mirrored.
- Anything you would hate to lose is either in a pushed repo, in a vault with a manifest, or in the mirror.

## Scripts

| Script | What it does | Writes |
|---|---|---|
| `Invoke-WorkstationAudit.ps1` | Read-only inventory: top-level folders with size and reclaimable build output, every git repo with remote/branch/dirty state/last commit, largest files, duplicate sets by SHA-256, tooling versions, OneDrive local vs cloud-only counts | `WORKSTATION_AUDIT\WORKSTATION_AUDIT.md` + CSVs |
| `Invoke-WorkstationLayout.ps1` | Creates the tree, plans every move from the audit and `workstation.json` rules into `moves.csv` (Move or Hold with the reason), and with `-Apply` executes the Move rows one at a time with a hash-chained log. Never deletes. | `moves.csv`, `C:\Unykorn\layout-log.jsonl` |
| `New-DocsIndex.ps1` | Seeds `30_DOCS` with ADR and runbook templates and writes `INDEX.md` linking every README, docs folder and ADR across all repositories with last-change dates | `30_DOCS\INDEX.md` |
| `workstation.json` | The layout, the routing rules (regex on folder name to destination), protected folders, staleness threshold | |

## Run order

```powershell
cd <clone>\tools\workstation
powershell -ExecutionPolicy Bypass -File .\Invoke-WorkstationAudit.ps1                       # read-only; open WORKSTATION_AUDIT.md
#   push every repo that shows "no remote" before going further
powershell -ExecutionPolicy Bypass -File .\Invoke-WorkstationLayout.ps1 -Audit "$env:USERPROFILE\WORKSTATION_AUDIT"          # plan; open moves.csv
powershell -ExecutionPolicy Bypass -File .\Invoke-WorkstationLayout.ps1 -Audit "$env:USERPROFILE\WORKSTATION_AUDIT" -Apply   # execute
powershell -ExecutionPolicy Bypass -File .\New-DocsIndex.ps1
cd C:\Unykorn\30_DOCS; git init; git add .; git commit -m "docs hub"                       # then add a remote and push
```

Hold rows in `moves.csv` are folders the rules could not place: a recently active folder with no rule, a code
container whose repos moved out individually, or a repo sitting inside OneDrive (clone it fresh into
`10_PLATFORMS` instead of moving it). Decide those by hand or add a rule to `workstation.json` and re-plan.

## Running Claude Code on this machine

Everything above was built remotely and run by hand. To have the same agent execute on the workstation with
approval on each write:

```powershell
winget install --id Git.Git -e
winget install --id OpenJS.NodeJS.LTS -e
npm install -g @anthropic-ai/claude-code
cd C:\Unykorn\10_PLATFORMS\ldx-capitol
claude
```

Then: "Run the workstation audit and show me the plan." The agent runs the scripts here, reads the output, and
proposes the next step. Nothing moves or deletes without a prompt you answer.
