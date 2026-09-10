# Appendix B  Files and paths

Where things live on an OS/7 machine — for when a cmdlet is not to hand, or you
want to see what one rests on.

## Identity and release

| Path | What is in it |
|---|---|
| `/usr/lib/os7/release.json` | the complete release description: version, channel, archive snapshot, components. `Get-OS7Version` reads it, `os7-setup` reads it, and the boot environment's name is built from it |
| `/usr/lib/os7/product` | the product name for every surface a person sees. A file of its own, so the branding depends on no `os-release` field |
| `/etc/os-release` | `PRETTY_NAME` is branded; `NAME`, `ID`, `VERSION` and `VERSION_ID` deliberately are not |
| `/etc/issue` | what stands at the console before sign-in |
| `/usr/lib/os7/migrations/` | the per-release migrations, as `<version>/<chroot\|firstboot>/NN-name` |

## Storage

| Path | What it is |
|---|---|
| `rpool/ROOT/os7_<version>_<time>` | the boot environment — `/` |
| `bpool/BOOT/os7_<version>_<time>` | its `/boot` |
| `rpool/USERDATA/<user>_<uuid>` | a home directory, outside the boot environment |
| `rpool/DATA/…` | state that survives a rollback: `log`, `spool`, `tmp`, `srv`, `lib/<service>`, `snapd` |
| `/dev/disk/by-partlabel/os7-luks` | the encrypted container `rpool` lives in |

## Boot

| Path | For |
|---|---|
| `/etc/grub.d/09_os7-boot-environments` | OS/7 generates its own boot menu here, one entry per boot environment |
| `/boot/efi/…/grub.cfg` | the file on the EFI partition that decides whose menu GRUB reads |
| `<boot environment>/boot/grub/grubenv` | `saved_entry` — which entry inside it starts |
| `/proc/cmdline` | the kernel command line. `boot=zfs` must be on it |

## Configuration

| Path | For |
|---|---|
| `/etc/netplan/*.yaml` | the network configuration. `Get-OS7NetworkConfiguration` merges it and names each statement's origin |
| `/etc/chrony/sources.d/*.sources` | the NTP sources. `Set-OS7TimeSynchronization` writes here, not into `chrony.conf` |
| `/etc/localtime` | the symlink that decides the time zone |
| `/etc/os7/backup.json` | the backup policy. Authoritative; the sanoid configuration is generated from it |
| `/etc/apt/sources.list.d/os7-release.*` | the OS/7 repository. Shipped deliberately disabled |

## Logs

| Path | What |
|---|---|
| `/var/log/os7-setup/install.log` | the installation record, with each step's self-proof. Mode `0600`, **inside** the boot environment. `Get-OS7InstallLog` |
| the systemd journal | `Get-OS7Log`. It lives under `/var/log`, so **outside** the boot environment — it survives the rollback of the update it explains |

## Programs and modules

| Path | What |
|---|---|
| `/usr/lib/os7-setup/os7-setup` | the installer. `--self-test`, `--version`, `--unattend`, `--dry-run` |
| `/usr/local/share/powershell/Modules/` | the six modules: `OS7`, `Zfs`, `Net`, `Time`, `Systemd`, `Directory` |
| `/usr/share/consolefonts/os7-console-16x32.psf.gz` | the installed console's font (Cascadia Mono) |
| `/usr/share/consolefonts/os7-fixedsys-16x32.psf.gz` | the installer's font (Fixedsys) |
| `/etc/profile.d/95-os7-powershell.sh` | the hand-off of the login shell to PowerShell |

## Services

| Unit | For |
|---|---|
| `os7-update-check.timer` / `.service` | the unattended update check |
| `os7-backup-replicate.service` | the replication run |
| `os7-migrations-firstboot.service` | the first-boot migrations after an update |
| `zfs-import-cache`, `zfs-mount`, `zfs-zed` | the ZFS chain at boot |
| `chrony.service` | the clock |
| `authd.service` | sign-in with Entra accounts |
