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

# Example usage and results:

PS $test = .\Get-DiskLayoutInfo.ps1
PS $test

Timestamp            DiskCount Disks
---------            --------- -----
10/5/2025 2:48:08 PM         3 {@{DiskNumber=0; Type=NVMe; Description=INTEL SSDPEKNU010TZ; DiskId={F20F0996-9676-4754-86E7-188FC5CEB528}; Connection=; Volumes=}, @{DiskNumber=1; Type=SATA; Description=Sam...


PS $test.Disks


DiskNumber  : 0
Type        : NVMe
Description : INTEL SSDPEKNU010TZ
DiskId      : {F20F0996-9676-4754-86E7-188FC5CEB528}
Connection  : @{Path=0; Target=0; LunId=0; LocationPath=PCIROOT(0)#PCI(0301)#PCI(0000)#NVME(P00T00L00)}
Volumes     : @{Volume=Volume 1; Ltr=D; Label=DATA; Fs=NTFS; Type=Partition; Size=953 GB; Status=Healthy; Info=; ByteSize=; SizeHuman=}

DiskNumber  : 1
Type        : SATA
Description : Samsung SSD 850 EVO 500GB
DiskId      : {4BE16DC4-3E72-11E8-A1F2-E03F49850ACF}
Connection  : @{Path=0; Target=0; LunId=0; LocationPath=PCIROOT(0)#PCI(1100)#ATA(C00T00L00)}
Volumes     : {@{Volume=Volume 2; Ltr=C; Label=; Fs=NTFS; Type=Partition; Size=464 GB; Status=Healthy; Info=Boot; ByteSize=; SizeHuman=}, @{Volume=Volume 3; Ltr=; Label=; Fs=FAT32; Type=Partition; Size=100
              MB; Status=Healthy; Info=System; ByteSize=; SizeHuman=}, @{Volume=Volume 4; Ltr=; Label=; Fs=NTFS; Type=Partition; Size=765 MB; Status=Healthy; Info=Hidden; ByteSize=; SizeHuman=}}

DiskNumber  : 2
Type        : USB
Description : SAMSUNG SP2504C USB Device
DiskId      : A915E769
Connection  : @{Path=0; Target=0; LunId=0; LocationPath=UNAVAILABLE}
Volumes     : {@{Volume=Volume 5; Ltr=F; Label=RECOVERY; Fs=FAT32; Type=Partition; Size=32 GB; Status=Healthy; Info=; ByteSize=; SizeHuman=}, @{Volume=Volume 6; Ltr=G; Label=BACKUP; Fs=NTFS; Type=Partition;
              Size=200 GB; Status=Healthy; Info=; ByteSize=; SizeHuman=}}



PS $test.Disks[0].volumes


Volume    : Volume 1
Ltr       : D
Label     : DATA
Fs        : NTFS
Type      : Partition
Size      : 953 GB
Status    : Healthy
Info      :
ByteSize  :
SizeHuman :



PS $test.Disks[0].connection

Path Target LunId LocationPath
---- ------ ----- ------------
0    0      0     PCIROOT(0)#PCI(0301)#PCI(0000)#NVME(P00T00L00)


PS $test = .\Get-DiskLayoutInfo.ps1 -IncludeDiskIds -AddSizeFields -IncludeDiskPartText
PS $test

Timestamp            DiskCount Disks
---------            --------- -----
10/5/2025 2:49:50 PM         3 {@{DiskNumber=0; Type=NVMe; Description=INTEL SSDPEKNU010TZ; DiskId={F20F0996-9676-4754-86E7-188FC5CEB528}; Connection=; Volumes=; SerialNumber=0000_0000_0100_0000_E4D2_5CD6_...


PS $test.Disks


DiskNumber    : 0
Type          : NVMe
Description   : INTEL SSDPEKNU010TZ
DiskId        : {F20F0996-9676-4754-86E7-188FC5CEB528}
Connection    : @{Path=0; Target=0; LunId=0; LocationPath=PCIROOT(0)#PCI(0301)#PCI(0000)#NVME(P00T00L00)}
Volumes       : @{Volume=Volume 1; Ltr=D; Label=DATA; Fs=NTFS; Type=Partition; Size=953 GB; Status=Healthy; Info=; ByteSize=1023275958272; SizeHuman=953.0 GB}
SerialNumber  : 0000_0000_0100_0000_E4D2_5CD6_AB8A_5601.
InterfaceType : SCSI
Model         : INTEL SSDPEKNU010TZ
PNPDeviceID   : SCSI\DISK&VEN_NVME&PROD_INTEL_SSDPEKNU01\5&4AEFD34&0&000000
RawDetail     : {, Microsoft DiskPart version 10.0.26100.1150, , Copyright (C) Microsoft Corporation....}

DiskNumber    : 1
Type          : SATA
Description   : Samsung SSD 850 EVO 500GB
DiskId        : {4BE16DC4-3E72-11E8-A1F2-E03F49850ACF}
Connection    : @{Path=0; Target=0; LunId=0; LocationPath=PCIROOT(0)#PCI(1100)#ATA(C00T00L00)}
Volumes       : {@{Volume=Volume 2; Ltr=C; Label=; Fs=NTFS; Type=Partition; Size=464 GB; Status=Healthy; Info=Boot; ByteSize=498216206336; SizeHuman=464.0 GB}, @{Volume=Volume 3; Ltr=; Label=; Fs=FAT32;
                Type=Partition; Size=100 MB; Status=Healthy; Info=System; ByteSize=104857600; SizeHuman=100.0 MB}, @{Volume=Volume 4; Ltr=; Label=; Fs=NTFS; Type=Partition; Size=765 MB; Status=Healthy;
                Info=Hidden; ByteSize=802160640; SizeHuman=765.0 MB}}
SerialNumber  : S2RBNXBH230133K
InterfaceType : IDE
Model         : Samsung SSD 850 EVO 500GB
PNPDeviceID   : SCSI\DISK&VEN_SAMSUNG&PROD_SSD_850_EVO_500G\4&FD895D1&0&000000
RawDetail     : {, Microsoft DiskPart version 10.0.26100.1150, , Copyright (C) Microsoft Corporation....}

DiskNumber    : 2
Type          : USB
Description   : SAMSUNG SP2504C USB Device
DiskId        : A915E769
Connection    : @{Path=0; Target=0; LunId=0; LocationPath=UNAVAILABLE}
Volumes       : {@{Volume=Volume 5; Ltr=F; Label=RECOVERY; Fs=FAT32; Type=Partition; Size=32 GB; Status=Healthy; Info=; ByteSize=34359738368; SizeHuman=32.0 GB}, @{Volume=Volume 6; Ltr=G; Label=BACKUP;
                Fs=NTFS; Type=Partition; Size=200 GB; Status=Healthy; Info=; ByteSize=214748364800; SizeHuman=200.0 GB}}
SerialNumber  : 152D203380B6
InterfaceType : USB
Model         : SAMSUNG SP2504C USB Device
PNPDeviceID   : USBSTOR\DISK&VEN_SAMSUNG&PROD_SP2504C&REV_\152D203380B6&0
RawDetail     : {, Microsoft DiskPart version 10.0.26100.1150, , Copyright (C) Microsoft Corporation....}



PS $test.Disks[1].volumes


Volume    : Volume 2
Ltr       : C
Label     :
Fs        : NTFS
Type      : Partition
Size      : 464 GB
Status    : Healthy
Info      : Boot
ByteSize  : 498216206336
SizeHuman : 464.0 GB

Volume    : Volume 3
Ltr       :
Label     :
Fs        : FAT32
Type      : Partition
Size      : 100 MB
Status    : Healthy
Info      : System
ByteSize  : 104857600
SizeHuman : 100.0 MB

Volume    : Volume 4
Ltr       :
Label     :
Fs        : NTFS
Type      : Partition
Size      : 765 MB
Status    : Healthy
Info      : Hidden
ByteSize  : 802160640
SizeHuman : 765.0 MB



PS $test.Disks[1].Connection

Path Target LunId LocationPath
---- ------ ----- ------------
0    0      0     PCIROOT(0)#PCI(1100)#ATA(C00T00L00)


PS $test.Disks[1].RawDetail

Microsoft DiskPart version 10.0.26100.1150

Copyright (C) Microsoft Corporation.
On computer: Computer1

Disk 1 is now the selected disk.

Samsung SSD 850 EVO 500GB
Disk ID: {4BE16DC4-3E72-11E8-A1F2-E03F49850ACF}
Type   : SATA
Status : Online
Path   : 0
Target : 0
LUN ID : 0
Location Path : PCIROOT(0)#PCI(1100)#ATA(C00T00L00)
Current Read-only State : No
Read-only  : No
Boot Disk  : Yes
Pagefile Disk  : Yes
Hibernation File Disk  : No
Crashdump Disk  : Yes
Clustered Disk  : No

  Volume ###  Ltr  Label        Fs     Type        Size     Status     Info
  ----------  ---  -----------  -----  ----------  -------  ---------  --------
  Volume 2     C                NTFS   Partition    464 GB  Healthy    Boot
  Volume 3                      FAT32  Partition    100 MB  Healthy    System
  Volume 4                      NTFS   Partition    765 MB  Healthy    Hidden

