# LD Capital / LDX archive migration

Two PowerShell scripts that consolidate every LD Capital, LDX, M Helen and Kiwi's Mulligan asset from the
OneDrive download tree and local LDX repositories onto the SanDisk, hash-verified, with a cumulative manifest
and an append-only chained log. Windows PowerShell 5.1 and PowerShell 7 are both supported.

| Script | Purpose |
|---|---|
| `Migrate-LDCapitalArchive.ps1` | Discover, classify, copy or move, verify, write manifests |
| `Verify-LDCapitalArchive.ps1` | Re-hash the archive against `manifest.json` and validate the log chain |

## Quick start

```powershell
# 1. Plan only. Nothing is written to the SanDisk; the manifest lands in %TEMP%\LD_Capital_Archive_DryRun.
powershell -ExecutionPolicy Bypass -File .\Migrate-LDCapitalArchive.ps1 -DryRun

# 2. Copy (sources untouched). The SanDisk is auto-detected; pass -Destination to override the drive letter.
powershell -ExecutionPolicy Bypass -File .\Migrate-LDCapitalArchive.ps1

# 3. Optional: move instead of copy. Each source is deleted only after its SHA-256 matches on the SanDisk.
powershell -ExecutionPolicy Bypass -File .\Migrate-LDCapitalArchive.ps1 -Mode Move

# 4. Verify at any later time (bit-rot, accidental edits, tampered log).
powershell -ExecutionPolicy Bypass -File .\Verify-LDCapitalArchive.ps1
```

Explicit drive letter and an explicit repo clone:

```powershell
.\Migrate-LDCapitalArchive.ps1 -Destination "E:\LD_Capital_Complete_Archive" -Repo "C:\Users\Kevan\source\ldx-capitol"
```

## What gets picked up

**Downloads sweep** (default root `C:\Users\Kevan\OneDrive - FTH Trading\11-Downloads`, recursive):

- everything under `_QUARANTINE_LD`, `_INTERNAL_ARCHIVE` and `sravan1` (folder-level inclusion, no name test);
- any other file whose name, or any folder on its path, matches one of the scope patterns:
  `LDX`, `LD Capital`, `LD Realty`, `LDRC`, `ldxcore`, `Kiwi`, `Mulligan`, `M Helen`, `Centrifuge`,
  `TD SYNNEX`, `UNYKORN-LDX` (case-insensitive; `LDX` requires a non-letter before it so `buildx` is not a hit).

**Repositories**: every git checkout up to three levels under the `-RepoRoot` folders whose name or top-level
markdown matches the scope patterns, plus anything passed with `-Repo`. By default only documentation is archived
(markdown, text, PDF, Office files, diagrams, and everything under `docs/`, `architecture/`, `specs/`, `design/`,
`adr/`, `wiki/`); `-RepoFullCopy` archives the whole tree. `.git`, `node_modules`, build output and IDE folders
are always excluded.

## Archive layout

```
<SanDisk>:\LD_Capital_Complete_Archive\
  Decks\                  pptx/key, and PDFs named deck, pitch, one-pager, teaser, overview…
  Legal_and_RegD\         Reg D, 506(c), PPM, subscription, operating agreement, NDA, term sheet, KYC/AML…
  SmartContracts\         .sol .rs .c .h .wasm .move .vy, and anything named hook, ERC-3643, T-REX, ONCHAINID…
  FinancialModels\        xlsx/csv, and anything named model, waterfall, pro forma, DSCR, LTV, cap table…
  Media\                  video, audio, images, design sources
  Architecture_Docs\      markdown/text/json/yaml, and anything named architecture, spec, whitepaper, command pack, master…
  Archives\               zip, 7z, rar, tar…
  Documents\              remaining PDF / Word documents
  Repos\<repo-name>\      repository files, original tree preserved
  Other\                  anything that matched scope but no category
  manifest.txt            human-readable: date, size, SHA-256, status, archive path, source path (grouped by category)
  manifest.csv            same rows for Excel
  manifest.json           same rows plus run metadata; cumulative across runs; consumed by the verifier
  migration-log.jsonl     append-only run log, every line carries prev + SHA-256 of itself (hash chain)
```

Inside each category the original sub-path under the source root is preserved, so
`11-Downloads\_QUARANTINE_LD\sub\LDX Capital Business Plan.pdf` lands at
`Documents\_QUARANTINE_LD\sub\LDX Capital Business Plan.pdf`.

## Guarantees

- **Hash-verified.** Every file is SHA-256 hashed at the source and again on the SanDisk. A mismatch removes the
  bad copy, marks the row `Failed`, and (in Move mode) leaves the source in place. Exit code 2 if anything failed.
- **Idempotent.** Re-running skips files already archived with an identical hash (`Duplicate`). A same-named file
  with different content is stored alongside as `name~<8-char-hash>.ext`; nothing is ever overwritten.
- **Cumulative manifest.** Rows from earlier runs are carried forward (`Archived`) as long as the file is still
  on the drive, so `manifest.json` always describes the whole archive.
- **Tamper-evident log.** `migration-log.jsonl` is append-only and hash-chained. Editing or deleting any line
  makes the verifier exit 5 and name the line.
- **Free-space gate.** The run aborts (exit 4) before copying if the SanDisk lacks the required space plus 2 percent.
- **Long paths.** Copies that exceed MAX_PATH fall back to `robocopy` automatically.
- **OneDrive Files-On-Demand.** Cloud-only placeholders are hydrated on read. Pass `-SkipCloudOnly` to leave
  them out and keep the run offline.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 2 | one or more files failed (see `Failed` rows in the manifest) / verifier found drift |
| 3 | no SanDisk or USB removable volume detected and no `-Destination` given / manifest missing |
| 4 | insufficient free space on the destination |
| 5 | verifier: log chain broken |

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `-SourcePath` | the OneDrive `11-Downloads` tree | one or more roots |
| `-IncludeFolder` | `_QUARANTINE_LD`, `_INTERNAL_ARCHIVE`, `sravan1` | whole-folder inclusion |
| `-Pattern` | see above | regexes applied to file names and path segments |
| `-RepoRoot` | `C:\Users\Kevan\source`, `...\repos`, `...\Documents\GitHub`, OneDrive `Documents\GitHub` | scanned for LDX repos |
| `-Repo` | none | explicit repository paths |
| `-RepoFullCopy` | off | archive whole repo trees |
| `-ExcludeDir` | `.git`, `node_modules`, `dist`, `build`, `target`, … | skipped anywhere on a path |
| `-Destination` | auto-detected SanDisk + `\LD_Capital_Complete_Archive` | override drive or folder |
| `-Mode` | `Copy` | `Move` deletes verified sources |
| `-SkipCloudOnly` | off | skip un-hydrated OneDrive placeholders |
| `-NoHash` | off | size-only verification (not recommended with `Move`) |
| `-DryRun` | off | plan only, destination untouched |
