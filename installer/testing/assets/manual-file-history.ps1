# One file, given a history, so the Versions window has something to draw.
#
# Pushed and run by installer/testing/shoot-desktop.py. It runs AS ROOT, because
# `zfs snapshot` is root's (VERSIONS-PLAN M-V22) -- but the file it writes
# belongs to the account, which is the whole point: the window is then opened by
# that account, and its restore takes V19's unprivileged branch.
#
# THREE OF THE FOUR SNAPSHOTS ARE A FIXTURE and the fourth is the machine's own.
# A machine twenty minutes old has none at all: sanoid's timer has not fired,
# and sanoid would not take four in one hour anyway, because a bucket that
# already has a snapshot for this hour is done. So the earlier three are taken
# with `zfs snapshot` under sanoid's naming -- which is what Get-OS7FileVersion
# reads the retention bucket from -- and the last is `Start-OS7Backup`, the
# product's own path, whose snapshot is sanoid's.
#
# The text is an invented quotation for an invented company. It is content for a
# picture and nothing else.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $Dataset
)

$ErrorActionPreference = 'Stop'

$owner = (/usr/bin/stat -c '%U' (Split-Path $Path)) 2>$null
if (-not $owner) { $owner = 'os7admin' }

# RE-RUNNABLE. A second run of shoot-desktop.py on the same bench would
# otherwise be a pile of "dataset already exists", and the run that matters is
# usually the second one.
foreach ($snap in (/usr/sbin/zfs list -t snapshot -o name -H -r $Dataset)) {
    /usr/sbin/zfs destroy $snap
}
Get-ChildItem (Split-Path $Path) -Filter "$(Split-Path $Path -Leaf)*" |
    Where-Object { $_.Name -like '*.os7-before-restore-*' } |
    Remove-Item -Force

function Write-Version([string] $Body) {
    Set-Content -LiteralPath $Path -Value $Body -NoNewline
    /usr/bin/chown "${owner}:${owner}" $Path
}

$v1 = @'
QUOTE 2026-114  --  Meyer Anlagenbau GmbH
=========================================

  3x  Workstation, 32 GB, 1 TB NVMe          2,940.00
  1x  Installation and handover                480.00
                                            ----------
                                    Total    3,420.00

Valid for 14 days. Delivery 3 weeks from order.
'@

$v2 = @'
QUOTE 2026-114  --  Meyer Anlagenbau GmbH
=========================================

  3x  Workstation, 32 GB, 1 TB NVMe          2,940.00
  1x  Installation and handover                480.00
  2x  Monitor, 27", height adjustable          618.00
                                            ----------
                                    Total    4,038.00

Valid for 14 days. Delivery 3 weeks from order.
'@

$v3 = @'
QUOTE 2026-114  --  Meyer Anlagenbau GmbH
=========================================

  3x  Workstation, 32 GB, 1 TB NVMe          2,940.00
  1x  Installation and handover                480.00
  2x  Monitor, 27", height adjustable          618.00
  1x  Dock, USB-C                              149.00
                                            ----------
                                    Total    4,187.00

Valid for 14 days. Delivery 3 weeks from order.
Discount 5% agreed by telephone on 21 September.
'@

$v4 = @'
QUOTE 2026-114  --  Meyer Anlagenbau GmbH
=========================================

  3x  Workstation, 32 GB, 1 TB NVMe          2,940.00
  1x  Installation and handover                480.00
  2x  Monitor, 27", height adjustable          618.00
  1x  Dock, USB-C                              149.00
                                            ----------
                                 Subtotal     4,187.00
                            Discount  5%       -209.35
                                            ----------
                                    Total     3,977.65

Valid for 14 days. Delivery 3 weeks from order.
'@

# THE LIVE FILE, and it is in no snapshot: the version a restore overwrites, and
# therefore the one the .os7-before-restore- file must end up holding.
$live = @'
QUOTE 2026-114  --  Meyer Anlagenbau GmbH
=========================================

  3x  Workstation, 32 GB, 1 TB NVMe          2,940.00
  1x  Installation and handover                480.00
                                            ----------
                                    Total    3,420.00

Monitors and dock withdrawn at the customer's request.
'@

$today = Get-Date -Format 'yyyy-MM-dd'
Write-Version $v1
/usr/sbin/zfs snapshot "${Dataset}@autosnap_${today}_00:00:07_monthly"
Write-Version $v2
/usr/sbin/zfs snapshot "${Dataset}@autosnap_${today}_07:00:03_daily"
Write-Version $v3
/usr/sbin/zfs snapshot "${Dataset}@autosnap_${today}_08:00:04_hourly"

Write-Version $v4
Import-Module OS7
$r = Start-OS7Backup -Confirm:$false
Write-Output "Start-OS7Backup: snapshotted=$($r.Snapshotted) taken=$($r.SnapshotsTaken)"

Write-Version $live

$n = @(Get-OS7FileVersion $Path).Count
Write-Output "versions of $(Split-Path $Path -Leaf): $n in snapshots, plus the live file"
if ($n -lt 3) {
    throw "only $n version(s) -- the window would have nothing worth a picture"
}
