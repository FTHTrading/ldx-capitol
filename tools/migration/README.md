# LD Capital / LDX archive migration

Two PowerShell scripts that consolidate every LD Capital, LDX, M Helen and Kiwi's Mulligan asset from the
OneDrive download tree and local LDX repositories onto the SanDisk, hash-verified, with a cumulative manifest
and an append-only chained log. Windows PowerShell 5.1 and PowerShell 7 are both supported.

| Script | Purpose |
|---|---|
| `Migrate-LDCapitalArchive.ps1` | Discover, classify, copy or move, verify, write manifests |
| `Verify-LDCapitalArchive.ps1` | Re-hash the archive against `manifest.json` and validate the log chain |
| `Build-LDCapitalMerkle.ps1` | Merkle tree over the manifest: root, per-file inclusion proofs, XRPL anchor payload |
| `anchor/xrpl-anchor.mjs` | Anchor the root on the XRP Ledger behind an explicit `--yes` gate; verify an anchor later |
| `Mirror-LDCapitalArchive.ps1` | Byte-verified second copy of the whole archive, tree preserved, to a sync folder, NAS or second drive |

## Adopting an archive that already exists

If the vault was assembled by other means (for example `D:\MASTER_LD_CAPITAL_AUDIT_VAULT` with its own
`00_…`/`08_…` layout), do not re-migrate it. Index it in place, then run the same integrity chain over it:

```powershell
cd <clone>\tools\migration
# 1. Hash every file where it sits; writes manifest.*, SHA256SUMS.txt, chain log. Nothing is moved or renamed.
powershell -ExecutionPolicy Bypass -File .\Migrate-LDCapitalArchive.ps1 -Destination "D:\MASTER_LD_CAPITAL_AUDIT_VAULT" -IndexOnly

# 2. Second copy, verified byte for byte. Do this before anything else touches the stick.
powershell -ExecutionPolicy Bypass -File .\Mirror-LDCapitalArchive.ps1 -Archive "D:\MASTER_LD_CAPITAL_AUDIT_VAULT" -Mirror "C:\Users\Kevan\OneDrive - FTH Trading\MASTER_LD_CAPITAL_AUDIT_VAULT"

# 3. Merkle root + anchor payload, then the XRPL anchor (see below).
powershell -ExecutionPolicy Bypass -File .\Build-LDCapitalMerkle.ps1 -Archive "D:\MASTER_LD_CAPITAL_AUDIT_VAULT" -Collection "MASTER_LD_CAPITAL_AUDIT_VAULT"

# 4. Any later day, on either copy:
powershell -ExecutionPolicy Bypass -File .\Verify-LDCapitalArchive.ps1 -Archive "D:\MASTER_LD_CAPITAL_AUDIT_VAULT"
```

Index mode records each file with Status `Indexed` and Category = its top-level folder, skips the control
files it writes itself, and leaves an existing `README.txt` alone. The verifier, Merkle builder and mirror all
auto-detect either `MASTER_LD_CAPITAL_AUDIT_VAULT` or `LD_Capital_Complete_Archive` on a removable volume.

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

## Evidence layer (optional, after the copy)

```powershell
# 5. Build the Merkle tree and anchor payload from manifest.json (writes merkle.json, merkle-root.txt, anchor-payload.json)
powershell -ExecutionPolicy Bypass -File .\Build-LDCapitalMerkle.ps1

# 6. Anchor the root on XRPL. First run prints the prepared transaction and stops; --yes signs and broadcasts.
cd anchor; npm install
$env:XRPL_ANCHOR_SEED = "<seed of the anchoring account>"        # this shell only, never on disk
node xrpl-anchor.mjs submit --payload D:\LD_Capital_Complete_Archive\anchor-payload.json --network testnet
node xrpl-anchor.mjs submit --payload D:\LD_Capital_Complete_Archive\anchor-payload.json --network testnet --yes --receipt D:\LD_Capital_Complete_Archive\anchor-receipt.json

# 7. Later: prove one file belongs to the anchored set, or re-derive the whole root from the bytes on the drive
powershell -ExecutionPolicy Bypass -File .\Build-LDCapitalMerkle.ps1 -VerifyProof "Business_Plans\misc\LDXCapitalBusinessPlan.pdf"
powershell -ExecutionPolicy Bypass -File .\Build-LDCapitalMerkle.ps1 -VerifyAll
node xrpl-anchor.mjs verify --receipt D:\LD_Capital_Complete_Archive\anchor-receipt.json --merkle D:\LD_Capital_Complete_Archive\merkle.json
```

Tree definition (deterministic, reproducible from `manifest.json` alone):

```
leaf = SHA-256( 0x00 || UTF8(archive path, '/' separators) || 0x00 || SHA-256(file) )
node = SHA-256( 0x01 || left || right )
leaves in ordinal path order; an unpaired node at any level is promoted unchanged
```

The anchor is an `AccountSet` with no flag changes and one memo (`ldx/archive-anchor/v1`, `application/json`)
carrying `{v, kind, root, n, run, col, ts}`. Cost is the network fee. No document, name, or hash list goes
on-chain; only the 32-byte root and counters. Switch `--network mainnet` once the testnet receipt verifies.

## What gets picked up

**Downloads sweep** (default root `C:\Users\Kevan\OneDrive - FTH Trading\11-Downloads`, recursive):

- everything under `_QUARANTINE_LD`, `_INTERNAL_ARCHIVE` and `sravan1` (folder-level inclusion, no name test);
- any other file whose name, or any folder on its path, matches one of the scope patterns:
  `LDX`, `LD Capital`, `LD Realty`, `LDRC`, `ldxcore`, `Kiwi`, `Mulligan`, `M Helen`, `Centrifuge`,
  `TD SYNNEX`, `UNYKORN-LDX` (case-insensitive; `LDX` requires a non-letter before it so `buildx` is not a hit);
- the `-Priority` must-haves, which are also scope patterns: LDX Capital Business Plan, LDX Enterprise Operating
  Manual, LD Capital Build Verification Deck, M Helen Data Room Master Index, Language Compliance Addendum,
  M Helen Hotel SPV, the UNYKORN LLC Executive Overview / Monetization Architecture / 7777 Institutional Bank
  decks, LDX-MASTER-SYSTEM, the WhiteLabel Command Pack, ldxcore, BUILD_PROOF. The manifest header and the console
  summary report FOUND or MISSING for each so a gap is visible before the drive leaves the desk. Unykorn files
  outside that list are not swept; add `'Unykorn'` to `-Pattern` if the whole Unykorn corpus should ride along.

**Repositories**: every git checkout up to three levels under the `-RepoRoot` folders whose name or top-level
markdown matches the scope patterns, plus anything passed with `-Repo`. By default only documentation is archived
(markdown, text, PDF, Office files, diagrams, and everything under `docs/`, `architecture/`, `specs/`, `design/`,
`adr/`, `wiki/`); `-RepoFullCopy` archives the whole tree. `.git`, `node_modules`, build output and IDE folders
are always excluded.

## Archive layout

```
<SanDisk>:\LD_Capital_Complete_Archive\
  Business_Plans\         anything named business plan, strategic plan, executive summary
  Operating_Manuals\      operating manuals, handbooks, SOPs
  Data_Room\              data-room indexes, master indexes, due-diligence packages
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
  SHA256SUMS.txt          sha256sum-compatible list: `sha256sum -c SHA256SUMS.txt` on any platform
  README.txt              layout and provenance notes for whoever opens the drive later
  migration-log.jsonl     append-only run log, every line carries prev + SHA-256 of itself (hash chain)
  merkle.json             (after Build-LDCapitalMerkle) root + inclusion proof for every file
  anchor-payload.json     (after Build-LDCapitalMerkle) what goes on-chain, with the memo hex ready for xrpl.js
  anchor-receipt.json     (after xrpl-anchor submit --yes) tx hash, ledger index, root
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

Name-based categories (`Business_Plans`, `Operating_Manuals`, `Data_Room`, then `Legal_and_RegD`,
`FinancialModels`, `SmartContracts`, `Decks`, `Architecture_Docs`) are tested after code, media and archive
extensions but before spreadsheet and deck extensions, so a data-room index that happens to be an `.xlsx` lands
in `Data_Room`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 2 | one or more files failed (see `Failed` rows in the manifest) / verifier found drift |
| 3 | no SanDisk or USB removable volume detected and no `-Destination` given / manifest missing |
| 4 | insufficient free space on the destination |
| 5 | verifier: log chain broken |
| 4 (mirror) | mirror path is inside the archive, or insufficient space |

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
| `-IndexOnly` | off | adopt the existing tree under `-Destination`; hash and record in place, copy nothing |
| `-DryRun` | off | plan only, destination untouched |
