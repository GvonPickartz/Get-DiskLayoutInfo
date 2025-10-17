<#
  .SYNOPSIS
    Retrieve disk and volume layout information via DiskPart.

  .DESCRIPTION
    Uses the Windows tool `diskpart.exe` to enumerate physical disks and their volumes.
    The table output is parsed using fixed-width column spans derived from the "###" header.
    If the header is missing, a simple English regex fallback handles lines that start with
    "Volume <n>". Optional features include size normalization, CIM/WMI identifier enrichment,
    and CSV/JSON export. Exports do not affect pipeline output.
    Also surfaces DiskPart identifiers (Disk ID) and connection hints (Path, Target, LUN ID, Location Path) - the latter are grouped under a Connection sub-object.
  
  .PARAMETER ReturnRaw
    Return only the array of per-disk objects (no summary wrapper).
  
  .PARAMETER MaxWaitSeconds
    Maximum time, in seconds, to wait for each DiskPart call. Default: 30.
  
  .PARAMETER DisplayProgress
    Show progress bars while DiskPart is running.
  
  .PARAMETER SkipMetadataLookup
    Skip CIM/WMI lookups for disk metadata (faster; fewer details).
  
  .PARAMETER IncludeDiskIds
    Include Model, PNPDeviceID, SerialNumber, and InterfaceType from CIM.
  
  .PARAMETER AddSizeFields
    Add ByteSize (Int64) and SizeHuman to each volume.
  
  .PARAMETER IncludeDiskPartText
    Include the raw DiskPart output (string[]) for each disk.
  
  .PARAMETER ReturnAsMap
    Return a hashtable mapping DiskNumber -> Volumes[].
  
  .PARAMETER ExportCsvPath
    Write a flattened volume list to CSV. Does not change pipeline output.
  
  .PARAMETER ExportJsonPath
    Write the full structure to JSON. Does not change pipeline output.
  
  .PARAMETER VolumeFilter
    Optional hashtable to filter results:
    - Disk : [int[]]     One or more disk numbers to include
    - Ltr  : [string[]]  Drive letters to include
    - Fs   : [string[]]  File system types to include
    - Info : [string]    Regex applied to the Info column
  
  .EXAMPLE
    Get-DiskLayoutInfo -IncludeDiskIds -AddSizeFields -ExportCsvPath .\volumes.csv -ExportJsonPath .\layout.json
  
  .EXAMPLE
    Get-DiskLayoutInfo -ReturnRaw | Format-Table DiskNumber, Type, Description
  
  .EXAMPLE
    Get-DiskLayoutInfo -ReturnAsMap
  
  .OUTPUTS
    Default        : [pscustomobject] @{ Timestamp; DiskCount; Disks = [pscustomobject[]] }
    With -ReturnRaw: [pscustomobject[]]  (array of disks with Volumes)
    With -ReturnAsMap: [hashtable]       (DiskNumber -> Volumes[])
    Each disk object includes DiskId and Connection (Path, Target, LunId, LocationPath).
  
  .NOTES
    Author          : G.A. von Pickartz
    Co-Author (AI)  : Codex CLI
    Version         : 1.0017.1710.2025
    License         : MIT
    Requires        : Windows with diskpart.exe; PowerShell 5.1+
  
  .LINK
    https://github.com/GvonPickartz/Get-DiskLayoutInfo
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param
(
  [switch]$ReturnRaw,
  [ValidateRange(1,600)][int]$MaxWaitSeconds = 30,
  [switch]$DisplayProgress,
  [switch]$SkipMetadataLookup,
  [switch]$IncludeDiskIds,
  [switch]$AddSizeFields,
  [switch]$IncludeDiskPartText,
  [switch]$ReturnAsMap,
  [string]$ExportCsvPath,
  [string]$ExportJsonPath,
  [hashtable]$VolumeFilter
)

begin {
  Write-Verbose "Begin: preparing helpers (MaxWaitSeconds=$MaxWaitSeconds, SkipMetadataLookup=$SkipMetadataLookup)."
  
  # Returns Array[Index] or '' if Index is out-of-bounds/null.
  # Keeps downstream property extraction simple and null-safe for PS5.    
  function Get-AtIndexOrEmpty {
    param ([object[]]$Array, [int]$Index)
    if ($null -ne $Array -and $Index -ge 0 -and $Index -lt $Array.Count) {
      return $Array[$Index]
    }
    ''
  }
  
  # Parse sizes like "953 GB", "100 MB", "512 B" into Int64 bytes.
  # Regex captures a number + unit; units are base-2 (KB=1024).    
  function ConvertTo-Bytes {
    param ([string]$SizeText)
    if ([string]::IsNullOrWhiteSpace($SizeText)) {
      return $null
    }
    $m = [regex]::Match($SizeText, '^\s*(\d+(?:\.\d+)?)\s*(B|KB|MB|GB|TB)\s*$', 'IgnoreCase')
    if (-not $m.Success) {
      return $null
    }
    $num = [double]$m.Groups[1].Value
    switch ($m.Groups[2].Value.ToUpperInvariant()) {
      'B'  {
        [int64]$num
      }
      'KB' {
        [int64]([math]::Round($num * 1KB))
      }
      'MB' {
        [int64]([math]::Round($num * 1MB))
      }
      'GB' {
        [int64]([math]::Round($num * 1GB))
      }
      'TB' {
        [int64]([math]::Round($num * 1TB))
      }
      default {
        $null
      }
    }
  }
  
  # Render Int64 bytes into a compact human string with one decimal (TB/GB/MB/KB),
  # falling back to raw bytes for small values. Mirrors ConvertTo-Bytes units.    
  function Format-Bytes {
    param ([Nullable[int64]]$Bytes)
    if ($null -eq $Bytes) {
      return ''
    }
    $b = [double]$Bytes
    if ($b -ge 1TB) {
      '{0:N1} TB' -f ($b/1TB)
    } elseif ($b -ge 1GB) {
      '{0:N1} GB' -f ($b/1GB)
    } elseif ($b -ge 1MB) {
      '{0:N1} MB' -f ($b/1MB)
    } elseif ($b -ge 1KB) {
      '{0:N1} KB' -f ($b/1KB)
    } else {
      '{0} B' -f [int64]$b
    }
  }
  
  # Compute fixed-width "column spans" based on the divider row (------ blocks).
  # If no divider is present, we fall back to word boundaries in the header.
  # Output is an array of [startIndex, length] pairs for Slice operations.    
  function Get-ColumnSpans {
    param ([Parameter(Mandatory)]
      [string]$Header, [string]$Divider)
    if ($Divider -and $Divider -match '-') {
      $spans = @(); $i = 0
      while ($i -lt $Divider.Length) {
        if ($Divider[$i] -eq '-') {
          $start = $i
          while ($i -lt $Divider.Length -and $Divider[$i] -eq '-') {
            $i++
          }
          $spans += ,@($start, ($i - $start))
        }
        $i++
      }
      if ($spans.Count -gt 0) {
        return, $spans
      }
    }
    # fallback based on header words
    $spans = @(); $in = $false; $start = 0
    for ($i = 0; $i -lt $Header.Length; $i++) {
      $ch = $Header[$i]
      if (-not $in -and $ch -ne ' ') {
        $in = $true; $start = $i
      } elseif ($in -and $ch -eq ' ') {
        $in = $false; $spans += ,@($start, ($i - $start))
      }
    }
    if ($in) {
      $spans += ,@($start, ($Header.Length - $start))
    }
     ,$spans
  }
  
  # Slice a text line into column values using spans from Get-ColumnSpans.
  # Trims each slice and safely handles lines shorter than the span.    
  function Get-SpanValues {
    param ([Parameter(Mandatory)]
      [string]$Line, [Parameter(Mandatory)]
      [object[]]$Spans)
    $values = @()
    foreach ($s in $Spans) {
      $start = [int]$s[0]; $len = [int]$s[1]
      $seg = if ($start -lt $Line.Length) {
        $Line.Substring($start, [Math]::Min($len, $Line.Length - $start)).Trim()
      } else {
        ''
      }
      $values += ,$seg
    }
     ,$values
  }
  
  # Convert a single "Volume ###" table row (fixed width) into an object.
  # When -AddSizeFields is set, also emit ByteSize/SizeHuman calculated fields.    
  function ConvertTo-VolumeObject {
    param ([Parameter(Mandatory)]
      [string]$Line, [Parameter(Mandatory)]
      [object[]]$Spans, [switch]$AddSizeFields)
    $v = Get-SpanValues -Line $Line -Spans $Spans
    $obj = [pscustomobject]@{
      Volume = Get-AtIndexOrEmpty -Array $v -Index 0
      Ltr    = Get-AtIndexOrEmpty -Array $v -Index 1
      Label  = Get-AtIndexOrEmpty -Array $v -Index 2
      Fs     = Get-AtIndexOrEmpty -Array $v -Index 3
      Type   = Get-AtIndexOrEmpty -Array $v -Index 4
      Size   = Get-AtIndexOrEmpty -Array $v -Index 5
      Status = Get-AtIndexOrEmpty -Array $v -Index 6
      Info   = Get-AtIndexOrEmpty -Array $v -Index 7
    }
    if ($AddSizeFields) {
      $bytes = ConvertTo-Bytes -SizeText $obj.Size
      Add-Member -InputObject $obj -NotePropertyName ByteSize -NotePropertyValue $bytes
      Add-Member -InputObject $obj -NotePropertyName SizeHuman -NotePropertyValue (Format-Bytes -Bytes $bytes)
    }
    $obj
  }
  
  # Looser, English-only fallback that parses lines beginning with "Volume <n>"
  # by collapsing runs of whitespace into a pseudo-delimiter. Helpful on hosts
  # where the divider/header pattern is inconsistent.    
  function ConvertTo-VolumeObjectFallback {
    param ([Parameter(Mandatory)]
      [string]$Line, [switch]$AddSizeFields)
    $clean = ($Line -replace '[\t ]{2,}', '|').Trim('|')
    $cols = $clean -split '\|'
    $map = @{
      Volume = ''; Ltr = ''; Label = ''; Fs = ''; Type = ''; Size = ''; Status = ''; Info = ''
    }
    foreach ($c in $cols) {
      $c = $c.Trim()
      if ($map.Volume -eq '' -and $c -match '^(?i)Volume\s+\d+') { $map.Volume = $c; continue }
      if ($map.Ltr -eq '' -and $c -match '^[A-Z]$') { $map.Ltr = $c; continue }
      if ($map.Fs -eq '' -and $c -match '^(?i)(NTFS|FAT32|exFAT|ReFS|UDF|FAT|CDFS|RAW)$') { $map.Fs = $c; continue }
      if ($map.Type -eq '' -and $c -match '^(?i)(Partition|Logical|Primary|Reserved|Removable|Unknown)$') { $map.Type = $c; continue }
      if ($map.Size -eq '' -and $c -match '^\d+(?:\.\d+)?\s?(KB|MB|GB|TB|B)$') { $map.Size = $c; continue }
      if ($map.Status -eq '' -and $c -match '^(?i)(Healthy|Offline|Failed|Unknown|Unusable)$') { $map.Status = $c; continue }
      if ($map.Info -eq '' -and $c -match '^(?i)(Boot|Hidden|System|None)$') { $map.Info = $c; continue }
      if ($map.Label -eq '' -and $c -ne '') { $map.Label = $c; continue }
    }
    $obj = [pscustomobject]$map
    if ($AddSizeFields) {
      $bytes = ConvertTo-Bytes -SizeText $obj.Size
      Add-Member -InputObject $obj -NotePropertyName ByteSize -NotePropertyValue $bytes
      Add-Member -InputObject $obj -NotePropertyName SizeHuman -NotePropertyValue (Format-Bytes -Bytes $bytes)
    }
    $obj
  }

  # Convert a single "Partition ###" table row (fixed width) into a simple object.
  function ConvertTo-PartitionObject {
    param (
      [Parameter(Mandatory)][string]$Line,
      [Parameter(Mandatory)][object[]]$Spans
    )
    $v = Get-SpanValues -Line $Line -Spans $Spans
    [pscustomobject]@{
      Partition = Get-AtIndexOrEmpty -Array $v -Index 0
      Type      = Get-AtIndexOrEmpty -Array $v -Index 1
      Size      = Get-AtIndexOrEmpty -Array $v -Index 2
      Offset    = Get-AtIndexOrEmpty -Array $v -Index 3
    }
  }

  # Looser fallback for lines beginning with "Partition <n>"
  function ConvertTo-PartitionObjectFallback {
    param ([Parameter(Mandatory)][string]$Line)
    $clean = ($Line -replace '[\t ]{2,}', '|').Trim('|')
    $cols = $clean -split '\|'
    [pscustomobject]@{
      Partition = ($cols | Select-Object -Index 0)
      Type      = ($cols | Select-Object -Index 1)
      Size      = ($cols | Select-Object -Index 2)
      Offset    = ($cols | Select-Object -Index 3)
    }
  }

  
  
  # Run DiskPart with a time bound. Shows progress when requested, and ensures
  # the process is terminated on timeout. Reads output from a temp file to avoid
  # deadlocks from stdout buffering. Returns the output as string[].
  function Invoke-DiskPart {
    [CmdletBinding()]
    param (
      [Parameter(Mandatory)]
      [string]$ScriptPath,
      [ValidateRange(1,600)][int]$MaxWaitSeconds = 30,
      [switch]$DisplayProgress,
      [int]$ParentProgressId = 0
    )
    
    $outFile = [System.IO.Path]::GetTempFileName()
    $proc = Start-Process -FilePath "$env:windir\System32\diskpart.exe" `
                          -ArgumentList "/s `"$ScriptPath`"" `
                          -RedirectStandardOutput $outFile `
                          -NoNewWindow -PassThru
    
    $elapsed = 0
    $subId = if ($ParentProgressId -gt 0) {
      $ParentProgressId + 1
    } else {
      1
    }
    Write-Verbose "Invoke-DiskPart started (PID=$($proc.Id)) script='$ScriptPath'"
    
    try {
      while (-not $proc.HasExited -and $elapsed -lt $MaxWaitSeconds) {
        if ($DisplayProgress) {
          Write-Progress -Id $subId -ParentId $ParentProgressId -Activity "DiskPart" `
                         -Status ("Running... {0}/{1}s" -f $elapsed, $MaxWaitSeconds) `
                         -PercentComplete ([int](($elapsed / [math]::Max(1, $MaxWaitSeconds)) * 100))
        }
        Start-Sleep -Seconds 1
        $elapsed++
      }
      
      if ($DisplayProgress) {
        Write-Progress -Id $subId -ParentId $ParentProgressId -Activity "DiskPart" -Completed
      }
      
      if (-not $proc.HasExited) {
        Write-Verbose "Invoke-DiskPart timed out after $MaxWaitSeconds s; terminating PID $($proc.Id)"
        try {
          $proc.Kill() | Out-Null
        } catch {
        }
        throw "DiskPart timeout after $MaxWaitSeconds seconds."
      }
      
      # Make sure ExitCode is populated and readable
      try {
        $proc.WaitForExit(100) | Out-Null
      } catch {
      }
      try {
        $proc.Refresh()
      } catch {
      }
      $exit = $null
      try {
        $exit = $proc.ExitCode
      } catch {
      }
      
      if (Test-Path -LiteralPath $outFile) {
        $lines = Get-Content -LiteralPath $outFile -ErrorAction SilentlyContinue
        $exitText = if ($null -eq $exit -or [string]::IsNullOrEmpty([string]$exit)) {
          '0'
        } else {
          [string]$exit
        }
        Write-Verbose "Invoke-DiskPart completed (exit=$exitText); captured $($lines.Count) lines"
        return, $lines
      }
      
      throw "DiskPart output file was not created."
    } finally {
      try {
        if (Test-Path -LiteralPath $outFile) {
          Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        }
      } catch {
      }
    }
  }
  
  # Cache-friendly CIM accessor: a single Win32_DiskDrive lookup for a DiskNumber.
  # Suppresses CIM's own -Verbose so our -Verbose stream stays readable.    
  function Get-DiskDriveCim {
    param ([Parameter(Mandatory)]
      [int]$DiskNumber)
    if ($SkipMetadataLookup) {
      return $null
    }
    if ($cimDiskCache.ContainsKey($DiskNumber)) {
      return $cimDiskCache[$DiskNumber]
    }
    $oldVerbose = $VerbosePreference
    try {
      $VerbosePreference = 'SilentlyContinue'
      $inst = Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop |
      Where-Object {
        $_.Index -eq $DiskNumber
      } |
      Select-Object -First 1 -Property Model, PNPDeviceID, SerialNumber, InterfaceType
      if ($inst) {
        $cimDiskCache[$DiskNumber] = $inst; return $inst
      }
    } catch {
    } finally {
      $VerbosePreference = $oldVerbose
    }
    return $null
  }
  
  # Convenience wrappers over Get-DiskDriveCim to return Model or a small ID map.    
  function Get-DiskModelCim {
    param ([Parameter(Mandatory)]
      [int]$DiskNumber)
    if ($SkipMetadataLookup) {
      return $null
    }
    $oldVerbose = $VerbosePreference
    try {
      $VerbosePreference = 'SilentlyContinue'
      (Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop |
        Where-Object {
          $_.Index -eq $DiskNumber
        } |
        Select-Object -First 1 -ExpandProperty Model).Trim()
    } catch {
      $null
    } finally {
      $VerbosePreference = $oldVerbose
    }
  }
  
  function Get-DiskIdsCim {
    param ([Parameter(Mandatory)]
      [int]$DiskNumber)
    if ($SkipMetadataLookup) {
      return @{
      }
    }
    $d = Get-DiskDriveCim -DiskNumber $DiskNumber
    if ($d) {
      return @{
        Model         = $d.Model
        PNPDeviceID   = $d.PNPDeviceID
        SerialNumber  = $d.SerialNumber
        InterfaceType = $d.InterfaceType
      }
    }
    @{
    }
  }
  
  # Cache Win32_DiskDrive by Index to avoid duplicate queries
  $cimDiskCache = @{
  }

  # MUI-neutral helpers and mappings for attributes
  function Expand-EnvPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try { [Environment]::ExpandEnvironmentVariables($Path) } catch { $Path }
  }

  # Build DriveLetter -> DiskNumber map
  $driveToDisk = @{}
  try {
    Get-Partition -ErrorAction Stop |
      Where-Object { $_.DriveLetter } |
      ForEach-Object { $driveToDisk[([string]$_.DriveLetter).ToUpperInvariant()] = $_.DiskNumber }
  } catch {}

  # Build sets of disk numbers that host pagefile/hiber/crashdump
  $pagefileDiskSet = @{}
  try {
    Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction Stop | ForEach-Object {
      $p = Expand-EnvPath $_.Name
      if ($p) {
        $root = [System.IO.Path]::GetPathRoot($p)
        if ($root -and $root.Length -ge 2) {
          $dl = $root[0].ToString().ToUpperInvariant()
          if ($driveToDisk.ContainsKey($dl)) { $pagefileDiskSet[$driveToDisk[$dl]] = $true }
        }
      }
    }
  } catch {}

  $hiberDiskSet = @{}
  try {
    $sys = $env:SystemDrive
    if ($sys) {
      $sys = $sys.TrimEnd('\\')
      if (Test-Path -LiteralPath (Join-Path $sys 'hiberfil.sys')) {
        $dl = $sys.TrimEnd(':').ToUpperInvariant()
        if ($driveToDisk.ContainsKey($dl)) { $hiberDiskSet[$driveToDisk[$dl]] = $true }
      }
    }
  } catch {}

  $crashDiskSet = @{}
  try {
    $cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
    $df = (Get-ItemProperty -Path $cc -Name DumpFile -ErrorAction SilentlyContinue).DumpFile
    $ddf = (Get-ItemProperty -Path $cc -Name DedicatedDumpFile -ErrorAction SilentlyContinue).DedicatedDumpFile
    foreach ($raw in @($df,$ddf)) {
      if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $p = Expand-EnvPath $raw
        $root = if ($p) { [System.IO.Path]::GetPathRoot($p) } else { $null }
        if ($root -and $root.Length -ge 2) {
          $dl = $root[0].ToString().ToUpperInvariant()
          if ($driveToDisk.ContainsKey($dl)) { $crashDiskSet[$driveToDisk[$dl]] = $true }
        }
      }
    }
  } catch {}
  $parentId = if ($DisplayProgress) {
    100
  } else {
    0
  }
  $diskObjects = New-Object System.Collections.Generic.List[object]
  $tempScript = [System.IO.Path]::GetTempFileName()
  
  Set-Content -LiteralPath $tempScript -Value "list disk" -Encoding ascii
  if ($DisplayProgress) {
    Write-Progress -Id $parentId -Activity "Get-DiskLayoutInfo" -Status "Listing disks..." -PercentComplete 10
  }
  Write-Verbose "Listing disks via DiskPart"
  $listOut = Invoke-DiskPart -ScriptPath $tempScript -MaxWaitSeconds $MaxWaitSeconds -DisplayProgress:$DisplayProgress -ParentProgressId $parentId
  
  # locate header with ### (Disk ### ...)
  $hdrIdx = -1
  for ($x = 0; $x -lt $listOut.Count; $x++) {
    if ($listOut[$x] -match '^\s*\S+\s+###\b') {
      $hdrIdx = $x; break
    }
  }
  if ($hdrIdx -lt 0) {
    $m = $listOut | Select-String -Pattern '###' | Select-Object -First 1
    if ($m) {
      $hdrIdx = $m.LineNumber - 1
    }
  }
  
  $diskNumbers = @()
  if ($hdrIdx -ge 0) {
    $start = $hdrIdx + 1
    if ($start -lt $listOut.Count -and $listOut[$start] -match '^\s*-+') {
      $start++
    }
    for ($j = $start; $j -lt $listOut.Count; $j++) {
      $ln = $listOut[$j]; if ([string]::IsNullOrWhiteSpace($ln)) {
        continue
      }
      $m = [regex]::Match($ln, '^\s*\D{0,8}(\d+)')
      if ($m.Success) {
        $diskNumbers += [int]$m.Groups[1].Value
      }
    }
  }
  
  $diskNumbers = $diskNumbers | Select-Object -Unique
  $totalDisks = $diskNumbers.Count
  
  Write-Verbose "Disks discovered: $totalDisks ($(($diskNumbers) -join ', '))"
  
  if ($totalDisks -eq 0) {
    if ($DisplayProgress) {
      Write-Progress -Id $parentId -Activity "Get-DiskLayoutInfo" -Status "0 disks found" -PercentComplete 100
      Write-Progress -Activity "Get-DiskLayoutInfo" -Completed
    }
    throw "No disks detected by DiskPart. Ensure administrative privileges and DiskPart availability."
  }
}

process {
  $i = 0
  # Batch: build a single DiskPart run for all disks to minimize prompts
  if ($DisplayProgress) {
    Write-Progress -Id $parentId -Activity "Get-DiskLayoutInfo" -Status ("Detailing {0} disk(s)..." -f $totalDisks) -PercentComplete 20
  }
  $cmds = New-Object System.Collections.Generic.List[string]
  foreach ($n in $diskNumbers) {
    $cmds.Add("select disk $n") | Out-Null
    $cmds.Add("detail disk") | Out-Null
  }
  Set-Content -LiteralPath $tempScript -Value ($cmds -join [Environment]::NewLine) -Encoding ascii
  $detailsOut = Invoke-DiskPart -ScriptPath $tempScript -MaxWaitSeconds $MaxWaitSeconds -DisplayProgress:$DisplayProgress -ParentProgressId $parentId

  # Split the combined output into per-disk sections
  $sections = @{}
  $current = $null
  foreach ($ln in $detailsOut) {
    if ($ln -match '^\s*Disk\s+(\d+)\s+is now the selected disk\.$') {
      $current = [int]$Matches[1]
      if (-not $sections.ContainsKey($current)) {
        $sections[$current] = New-Object System.Collections.Generic.List[string]
      }
      continue
    }
    if ($null -ne $current) {
      $sections[$current].Add($ln) | Out-Null
    }
  }
  try {
    foreach ($n in $diskNumbers) {
      $i++
      if ($DisplayProgress) {
        Write-Progress -Id $parentId -Activity "Get-DiskLayoutInfo" -Status ("Detail disk {0}/{1}" -f $i, $totalDisks) -PercentComplete (($i/[math]::Max(1, $totalDisks)) * 100)
      }
      Write-Verbose "Assembling details for Disk $n"
      $detail = if ($sections.ContainsKey($n)) { $sections[$n].ToArray() } else { @() }
      
      # Disk metadata
      $diskType = ($detail | Where-Object {
          $_ -match '^\s*Type\s*:\s*(.+)$'
        } | ForEach-Object {
          ($Matches[1]).Trim()
        } | Select-Object -First 1)
      $diskDesc = ($detail | Where-Object {
          $_ -match '^\s*(Model|Name|Description)\s*:\s*(.+)$'
        } |
        ForEach-Object {
          if ($Matches.Count -ge 3) {
            ($Matches[2]).Trim()
          }
        } |
        Select-Object -First 1)
      if ([string]::IsNullOrWhiteSpace($diskDesc)) {
        $diskDesc = Get-DiskModelCim -DiskNumber $n
      }
      # DiskPart identifiers & connection info (cheap to parse)
      $diskId = ($detail | Where-Object {
          $_ -match '^\s*Disk ID\s*:\s*(.+)$'
        } |
        ForEach-Object {
          ($Matches[1]).Trim()
        } | Select-Object -First 1)
      
      $pathVal = ($detail | Where-Object {
          $_ -match '^\s*Path\s*:\s*(.+)$'
        } |
        ForEach-Object {
          ($Matches[1]).Trim()
        } | Select-Object -First 1)
      
      $targetVal = ($detail | Where-Object {
          $_ -match '^\s*Target\s*:\s*(.+)$'
        } |
        ForEach-Object {
          ($Matches[1]).Trim()
        } | Select-Object -First 1)
      
      $lunVal = ($detail | Where-Object {
          $_ -match '^\s*LUN ID\s*:\s*(.+)$'
        } |
        ForEach-Object {
          ($Matches[1]).Trim()
        } | Select-Object -First 1)
      
      $locPathVal = ($detail | Where-Object {
          $_ -match '^\s*Location Path\s*:\s*(.+)$'
        } |
        ForEach-Object {
          ($Matches[1]).Trim()
        } | Select-Object -First 1)
      
      # Group connection hints under a single sub-object
      $connection = [pscustomobject]@{
        Path         = $pathVal
        Target       = $targetVal
        LunId        = $lunVal
        LocationPath = $locPathVal
      }
      
      # Volumes (primary, via spans)
      $vHdr = -1; $vDiv = $null
      # Locate the "###" header that precedes the fixed-width table.
      # We don't break on the first match to mimic legacy behavior.
      for ($k = 0; $k -lt $detail.Count; $k++) {
        if ($detail[$k] -match '^\s*\S+\s+###\b') {
          $vHdr = $k
        } # no break, same as legacy
      }
      
      $vols = @()
      if ($vHdr -ge 0) {
        $start = $vHdr + 1
        if ($start -lt $detail.Count -and $detail[$start] -match '^\s*-+') {
          $vDiv = $detail[$start]; $start++
        }
        $spans = Get-ColumnSpans -Header $detail[$vHdr] -Divider $vDiv
        for ($r = $start; $r -lt $detail.Count; $r++) {
          $row = $detail[$r]
          if ([string]::IsNullOrWhiteSpace($row)) {
            continue
          }
          $first = (Get-SpanValues -Line $row -Spans $spans)[0]
          if ($first -notmatch '^\d+$') {
            continue
          }
          
          $vols += ConvertTo-VolumeObject -Line $row -Spans $spans -AddSizeFields:$AddSizeFields
        }
      }
      
      # Fallback: if no spans-derived rows were found, scan for English "Volume <n>" lines.
      # This keeps behavior consistent on quirky/older builds or localized outputs.        
      if (-not $vols -or $vols.Count -eq 0) {
        # Locale-neutral fallback: accept any token followed by a number, split by whitespace runs
        $dataLines = $detail | Where-Object {
          $_ -match '^\s*\S+\s+\d+'
        }
        foreach ($line in $dataLines) {
          $vols += ConvertTo-VolumeObjectFallback -Line $line -AddSizeFields:$AddSizeFields
        }
      }

      # Partition fallback: if still no volumes, synthesize rows from "Partition ###" table
      if (-not $vols -or $vols.Count -eq 0) {
        $pHdr = -1; $pDiv = $null
        for ($k = 0; $k -lt $detail.Count; $k++) {
          if ($detail[$k] -match '^\s*\S+\s+###\b') { $pHdr = $k }
        }
        $parts = @()
        if ($pHdr -ge 0) {
          $pStart = $pHdr + 1
          if ($pStart -lt $detail.Count -and $detail[$pStart] -match '^\s*-+') { $pDiv = $detail[$pStart]; $pStart++ }
          $pSpans = Get-ColumnSpans -Header $detail[$pHdr] -Divider $pDiv
          for ($r = $pStart; $r -lt $detail.Count; $r++) {
            $row = $detail[$r]
            if ([string]::IsNullOrWhiteSpace($row)) { continue }
            $first = (Get-SpanValues -Line $row -Spans $pSpans)[0]
            if ($first -notmatch '^\d+$') { continue }
            $parts += ConvertTo-PartitionObject -Line $row -Spans $pSpans
          }
        }
        if (-not $parts -or $parts.Count -eq 0) {
          $pLines = $detail | Where-Object { $_ -match '^\s*\S+\s+\d+' }
          foreach ($line in $pLines) { $parts += ConvertTo-PartitionObjectFallback -Line $line }
        }
        if ($parts -and $parts.Count -gt 0) {
          foreach ($p in $parts) {
            $o = [pscustomobject]@{
              Volume = $p.Partition
              Ltr    = ''
              Label  = ''
              Fs     = 'RAW'
              Type   = 'Partition'
              Size   = $p.Size
              Status = ''
              Info   = 'RAW/Unformatted'
            }
            if ($AddSizeFields) {
              $bytes = ConvertTo-Bytes -SizeText $o.Size
              Add-Member -InputObject $o -NotePropertyName ByteSize -NotePropertyValue $bytes
              Add-Member -InputObject $o -NotePropertyName SizeHuman -NotePropertyValue (Format-Bytes -Bytes $bytes)
            }
            $vols += $o
          }
        }
        if (-not $vols -or $vols.Count -eq 0) {
          $vols = @([pscustomobject]@{ Volume='-'; Ltr=''; Label=''; Fs=''; Type=''; Size=''; Status=''; Info='No volumes found (RAW/Offline?)' })
        }
      }
      
      # Only emit a short preview when the header is missing; helps diagnose edge layouts
      # without spamming the verbose stream during normal runs.
      if ($vHdr -lt 0 -and $detail.Count -gt 0) {
        Write-Verbose ("First detail lines:`n" + ($detail | Select-Object -First 5 | Out-String).TrimEnd())
      }

      # Disk attributes (booleans) via OS APIs (MUI-neutral)
      $attributes = $null
      try {
        $dsk = $null
        try { $dsk = Get-Disk -Number $n -ErrorAction Stop } catch {}
        $ro   = if ($dsk) { [bool]$dsk.IsReadOnly } else { $false }
        $boot = if ($dsk) { ([bool]$dsk.IsBoot -or [bool]$dsk.IsSystem) } else { $false }
        $clus = if ($dsk) { [bool]$dsk.IsClustered } else { $false }
        $pf   = [bool]($pagefileDiskSet.ContainsKey($n))
        $hib  = [bool]($hiberDiskSet.ContainsKey($n))
        $cr   = [bool]($crashDiskSet.ContainsKey($n))
        $attributes = [pscustomobject]@{
          CurrentReadOnlyState = $ro
          ReadOnly             = $ro
          BootDisk             = $boot
          PagefileDisk         = $pf
          HibernationFileDisk  = $hib
          CrashdumpDisk        = $cr
          ClusteredDisk        = $clus
        }
      } catch { $attributes = [pscustomobject]@{} }

      
      $disk = [pscustomobject]@{
        DiskNumber  = $n
        Type        = $diskType
        Description = $diskDesc
        DiskId      = $diskId
        Connection  = $connection
        Attributes  = $attributes
        Volumes     = $vols | Select-Object Volume, Ltr, Label, Fs, Type, Size, Status, Info,
                                            @{
          N = 'ByteSize'; E = {
            $_.ByteSize
          }
        },
                                            @{
          N = 'SizeHuman'; E = {
            $_.SizeHuman
          }
        }
      }
      
      if ($IncludeDiskIds) {
        $ids = Get-DiskIdsCim -DiskNumber $n
        foreach ($k in $ids.Keys) {
          Add-Member -InputObject $disk -NotePropertyName $k -NotePropertyValue $ids[$k]
        }
      }
      if ($IncludeDiskPartText) {
        Add-Member -InputObject $disk -NotePropertyName RawDetail -NotePropertyValue $detail
      }
      
      $diskObjects.Add($disk) | Out-Null
    }
  } finally {
    try {
      if (Test-Path -LiteralPath $tempScript) {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
      }
    } catch {
    }
  }
}

end {
  if ($DisplayProgress) {
    Write-Progress -Activity "Get-DiskLayoutInfo" -Completed
  }
  Write-Verbose "End: assembling outputs and optional exports."
  
  $disks = if ($diskObjects) {
    $diskObjects.ToArray()
  } else {
    @()
  }
  
  # Exports are best-effort and do not change pipeline output.
  # Errors are surfaced as warnings so the pipeline remains usable.
  
  # Optional CSV export (flattened)
  try {
    if ($ExportCsvPath) {
      $dir = Split-Path -Parent $ExportCsvPath
      if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
      }
      $flat = foreach ($d in $disks) {
        $a = $d.PSObject.Properties['Attributes'].Value
        $c = $d.PSObject.Properties['Connection'].Value
        foreach ($v in $d.Volumes) {
          [pscustomobject]@{
            DiskNumber                 = $d.DiskNumber
            Type                       = $d.Type
            Description                = $d.Description
            DiskId                     = $d.PSObject.Properties['DiskId'].Value
            Volume                     = $v.Volume
            Ltr                        = $v.Ltr
            Label                      = $v.Label
            Fs                         = $v.Fs
            VolType                    = $v.Type
            Size                       = $v.Size
            ByteSize                   = $v.PSObject.Properties['ByteSize'].Value
            SizeHuman                  = $v.PSObject.Properties['SizeHuman'].Value
            Status                     = $v.Status
            Info                       = $v.Info
            AttrCurrentReadOnlyState   = $(if ($a) { [bool]$a.CurrentReadOnlyState } else { $null })
            AttrReadOnly               = $(if ($a) { [bool]$a.ReadOnly } else { $null })
            AttrBootDisk               = $(if ($a) { [bool]$a.BootDisk } else { $null })
            AttrPagefileDisk           = $(if ($a) { [bool]$a.PagefileDisk } else { $null })
            AttrHibernationFileDisk    = $(if ($a) { [bool]$a.HibernationFileDisk } else { $null })
            AttrCrashdumpDisk          = $(if ($a) { [bool]$a.CrashdumpDisk } else { $null })
            AttrClusteredDisk          = $(if ($a) { [bool]$a.ClusteredDisk } else { $null })
            ConnPath                   = $(if ($c) { $c.Path } else { $null })
            ConnTarget                 = $(if ($c) { $c.Target } else { $null })
            ConnLunId                  = $(if ($c) { $c.LunId } else { $null })
            ConnLocationPath           = $(if ($c) { $c.LocationPath } else { $null })
            SerialNumber               = $d.PSObject.Properties['SerialNumber'].Value
            InterfaceType              = $d.PSObject.Properties['InterfaceType'].Value
            Model                      = $d.PSObject.Properties['Model'].Value
            PNPDeviceID                = $d.PSObject.Properties['PNPDeviceID'].Value
          }
        }
      }
      Write-Verbose "Writing CSV to $ExportCsvPath"
      $flat | Export-Csv -Path $ExportCsvPath -NoTypeInformation -Encoding ascii
    }
  } catch {
    Write-Warning ("CSV export failed: {0}" -f $_.Exception.Message)
  }
  
  # Optional JSON export (structured)
  try {
    if ($ExportJsonPath) {
      $dir = Split-Path -Parent $ExportJsonPath
      if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
      }
      
      if ($ReturnAsMap) {
        $toSave = @{
        }; foreach ($d in $disks) {
          $toSave[[string]$d.DiskNumber] = $d.Volumes
        }
      } elseif ($ReturnRaw) {
        $toSave = $disks
      } else {
        $toSave = [pscustomobject]@{
          Timestamp = Get-Date; DiskCount = $disks.Count; Disks = $disks
        }
      }
      
      Write-Verbose "Writing JSON to $ExportJsonPath"
      ($toSave | ConvertTo-Json -Depth 6) | Out-File -FilePath $ExportJsonPath -Encoding ascii
    }
  } catch {
    Write-Warning ("JSON export failed: {0}" -f $_.Exception.Message)
  }
  
  # Return pipeline result
  if ($ReturnAsMap) {
    $map = @{
    }; foreach ($d in $disks) {
      $map[[string]$d.DiskNumber] = $d.Volumes
    }
    return $map
  }
  if ($ReturnRaw) {
    return $disks
  }
  
  # Post-filtering by Disk/Ltr/Fs/Info happens after enumeration,
  # keeping the main discovery path simple and predictable.    
  if ($VolumeFilter) {
    Write-Verbose "Applying VolumeFilter: $($VolumeFilter.Keys -join ', ')"
    $wantDisks = if ($VolumeFilter.ContainsKey('Disk')) {
      @($VolumeFilter['Disk'])
    } else {
      @()
    }
    $disks = foreach ($d in $disks) {
      if ($wantDisks.Count -gt 0 -and ($wantDisks -notcontains $d.DiskNumber)) {
        continue
      }
      $v = $d.Volumes
      if ($VolumeFilter.ContainsKey('Ltr')) {
        $v = $v | Where-Object {
          @($VolumeFilter['Ltr']) -contains $_.Ltr
        }
      }
      if ($VolumeFilter.ContainsKey('Fs')) {
        $v = $v | Where-Object {
          @($VolumeFilter['Fs']) -contains $_.Fs
        }
      }
      if ($VolumeFilter.ContainsKey('Info')) {
        $v = $v | Where-Object {
          $_.Info -match [string]$VolumeFilter['Info']
        }
      }
      [pscustomobject]@{
        DiskNumber = $d.DiskNumber; Type = $d.Type; Description = $d.Description; Volumes = $v
      }
    }
  }
  
  [pscustomobject]@{
    Timestamp = Get-Date
    DiskCount = $disks.Count
    Disks     = $disks
  }
}
