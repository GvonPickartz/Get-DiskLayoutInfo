# Get-DiskLayoutInfo

Retrieve disk and volume layout information via DiskPart — with optional CIM/WMI enrichment and CSV/JSON export.  
✅ PowerShell 5.1+ on Windows • MIT licensed • No external dependencies.

## Features
- Parses DiskPart’s fixed-width tables (MUI/locale resilient) with a regex fallback.
- Optional CIM/WMI identifiers (Model, Serial, Interface).
- Optional size normalization (bytes + human-readable).
- Optional CSV/JSON export (does not affect pipeline output).
- Verbose tracing and progress support. No file logging.

## Requirements
- Windows with `diskpart.exe` available in `PATH`
- PowerShell 5.1+ (Windows PowerShell)

## Install / Use
Clone, then dot-source the function, or import from your script:

```powershell
# dot-source once per session
. "$PSScriptRoot\src\Get-DiskLayoutInfo.ps1"

# basic run
Get-DiskLayoutInfo

# add CIM IDs + normalized sizes
Get-DiskLayoutInfo -IncludeDiskIds -AddSizeFields

# export, but don’t change pipeline output
Get-DiskLayoutInfo -AddSizeFields -ExportCsvPath .\volumes.csv -ExportJsonPath .\layout.json

# raw disk array (no summary wrapper)
Get-DiskLayoutInfo -ReturnRaw | Format-Table DiskNumber, Type, Description

# hashtable view: DiskNumber -> Volumes[]
Get-DiskLayoutInfo -ReturnAsMap

# filtering
Get-DiskLayoutInfo -VolumeFilter @{ Disk = 0,1; Ltr = 'C','D'; Fs='NTFS' }
