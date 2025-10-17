# Get-DiskLayoutInfo

MUI‑neutral DiskPart.exe → PowerShell translator for disk and volume layout, with optional CIM/WMI enrichment and CSV/JSON export. Built for fast, dependable inventory and troubleshooting on Windows PowerShell 5.1.

## Summary
- Translates DiskPart ASCII into clean, usable PowerShell objects.
- MUI‑neutral across locales: no reliance on English keywords.
- Disk‑level Attributes as booleans (BootDisk, ReadOnly, etc.).
- RAW/partition fallback when volume tables are absent.
- Minimal deps: Windows + DiskPart + PowerShell 5.1.

## Why MUI‑Neutral Matters
- DiskPart output changes with OS language (MUI). Naive string matching breaks on non‑en‑US.
- This tool avoids language coupling by:
  - Using fixed‑width parsing anchored on the numeric “###” header + dashed divider.
  - Falling back to locale‑neutral heuristics (token + number) when headers are missing.
  - Deriving disk Attributes via OS APIs (Storage cmdlets, WMI, registry) instead of text scraping.

## Requirements
- Windows with `diskpart.exe`
- PowerShell 5.1 (run elevated for best results)

## Quick Start
```powershell
# Run once with no prompts
powershell -NoProfile -ExecutionPolicy Bypass -File .\Get-DiskLayoutInfo.ps1 -AddSizeFields

# Or from the current PS session
Unblock-File .\Get-DiskLayoutInfo.ps1
Set-ExecutionPolicy Bypass -Scope Process -Force
./Get-DiskLayoutInfo.ps1 -AddSizeFields
```

Expected: summary object with `Timestamp`, `DiskCount`, and `Disks` (array). Use `-ReturnRaw` for the array directly.

## Usage
```powershell
# Default summary
./Get-DiskLayoutInfo.ps1

# Raw disk array (no summary wrapper)
./Get-DiskLayoutInfo.ps1 -ReturnRaw | Format-Table DiskNumber, Type, Description

# Map view: DiskNumber -> Volumes[]
./Get-DiskLayoutInfo.ps1 -ReturnAsMap

# Export without changing pipeline output
./Get-DiskLayoutInfo.ps1 -AddSizeFields -ExportCsvPath .\out\volumes.csv -ExportJsonPath .\out\layout.json
```

Admin tip: For full DiskPart details, run your session as Administrator.

## Common Options
- `-IncludeDiskIds` — Add `Model`, `PNPDeviceID`, `SerialNumber`, `InterfaceType` from CIM.
- `-AddSizeFields` — Add `ByteSize` and `SizeHuman` to each volume.
- `-IncludeDiskPartText` — Attach the raw DiskPart text per disk (`RawDetail`).
- `-MaxWaitSeconds <int>` — Timeout for DiskPart calls (default 30s).
- `-ReturnRaw` — Return only the array of disk objects.
- `-ReturnAsMap` — Return a hashtable: DiskNumber → `Volumes[]`.
- `-ExportCsvPath <path>` — Write a flattened volume list to CSV.
- `-ExportJsonPath <path>` — Write the full structure to JSON.
- `-VolumeFilter @{ Disk; Ltr; Fs; Info }` — Filter after enumeration.

## Examples
```powershell
# Only boot disks
./Get-DiskLayoutInfo.ps1 -ReturnRaw | Where-Object { $_.Attributes.BootDisk } |
  Format-Table DiskNumber, Type, Description

# Find any read-only disks
./Get-DiskLayoutInfo.ps1 -ReturnRaw | Where-Object { $_.Attributes.ReadOnly } |
  Format-List DiskNumber, Attributes

# Filter by drive letter or file system
./Get-DiskLayoutInfo.ps1 -ReturnRaw -VolumeFilter @{ Ltr = 'C','D'; Fs = 'NTFS' } |
  ForEach-Object { $dn=$_.DiskNumber; $_.Volumes | Select-Object @{N='Disk';E={$dn}},Ltr,Fs,Size }

# Export CSV + JSON (and still get normal pipeline output)
./Get-DiskLayoutInfo.ps1 -AddSizeFields -ExportCsvPath .\out\volumes.csv -ExportJsonPath .\out\layout.json
```

## Output Shapes
- Default (summary):
  - `[pscustomobject]` with `Timestamp`, `DiskCount`, `Disks=[pscustomobject[]]`
- `-ReturnRaw`:
  - `[pscustomobject[]]` — one object per disk, each with `Connection`, `Attributes`, and `Volumes[]`
- `-ReturnAsMap`:
  - `[hashtable]` mapping `DiskNumber (string)` → `Volumes[]`

Disk object (typical):
- `DiskNumber`, `Type`, `Description`, `DiskId`
- `Connection` (`Path`, `Target`, `LunId`, `LocationPath`)
- `Attributes` (booleans): `CurrentReadOnlyState`, `ReadOnly`, `BootDisk`, `PagefileDisk`, `HibernationFileDisk`, `CrashdumpDisk`, `ClusteredDisk`
- `Volumes[]`: `Volume`, `Ltr`, `Label`, `Fs`, `Type`, `Size`, `Status`, `Info`, plus `ByteSize`/`SizeHuman` when `-AddSizeFields`

## How It Works
- Exactly two DiskPart calls per run:
  1) `list disk` to discover disk numbers
  2) One combined script with repeated `select disk N` + `detail disk` for all disks
- Parses fixed‑width tables using column spans (header “###” + dashed divider).
- When headers are missing, falls back to locale‑neutral row detection (first token + number).
- If no “Volume ###” table is present, partitions are parsed and surfaced as RAW entries (`Fs='RAW'`, `Type='Partition'`).
- Disk Attributes are API‑derived (Get‑Disk, WMI, registry) and exposed as booleans under `Attributes`.

## Performance & Limits
- Reduced prompts and faster execution via batching.
- Best results when run elevated (Administrator).
- The parser expects English labels for the attribute lines; if you use a non‑English OS, open an issue with a sample of `-IncludeDiskPartText` output.

## Troubleshooting
- Execution policy: unblock or bypass
  - `Unblock-File .\Get-DiskLayoutInfo.ps1`
  - `Set-ExecutionPolicy Bypass -Scope Process -Force`
- Timeout: increase `-MaxWaitSeconds` when detailing many disks.
- Empty `Volumes`: disk is offline/RAW/has no mounted volumes; RAW partition fallback may populate entries for visibility.
- Inspect raw text: use `-IncludeDiskPartText` and view `RawDetail`.

## Versioning
- Format: `major.daily.ddMM.YYYY`
 - Current: `1.0017.1710.2025`

## License
MIT

## Author
- G.A. von Pickartz
- Co-Author (AI): Codex CLI

## Changelog

- 2025-10-17 — v1.0017.1710.2025
  - CSV export: add Conn* fields (Path/Target/LunId/LocationPath) and DiskId/IDs (when -IncludeDiskIds).
  - CSV export: include Attr* booleans per row.
  - Minor README polishing for translator focus.

- 2025-10-17 — v1.0016.1710.2025
  - MUI hardening: locale-neutral volume and partition detection (span header or token+number fallback).
  - Disk attributes made language-independent (API-derived booleans via Get-Disk, WMI, registry).
  - Batch DiskPart calls: one `list disk` + one combined `detail disk` script.
  - RAW partition fallback when no volume table is present.
  - README rewritten: translator focus, MUI neutrality, usage and examples.
  - Versioning and co-author attribution added; script normalized to CRLF.
