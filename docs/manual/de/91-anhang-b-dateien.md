# Anhang B  Dateien und Pfade

Wo auf einer OS/7-Maschine etwas steht — für den Fall, dass ein Cmdlet nicht
zur Hand ist oder man nachsehen will, worauf es sich stützt.

## Identität und Release

| Pfad | Was darin steht |
|---|---|
| `/usr/lib/os7/release.json` | die vollständige Release-Beschreibung: Version, Kanal, Archiv-Snapshot, Bestandteile. `Get-OS7Version` liest sie, `os7-setup` liest sie, der Name der Bootumgebung wird daraus gebildet |
| `/usr/lib/os7/product` | der Produktname für alle Oberflächen, die ein Mensch sieht. Eine eigene Datei, damit die Markierung von keinem `os-release`-Feld abhängt |
| `/etc/os-release` | `PRETTY_NAME` ist gebrandet, `NAME`, `ID`, `VERSION` und `VERSION_ID` bewusst nicht |
| `/etc/issue` | was vor der Anmeldung an der Konsole steht |
| `/usr/lib/os7/migrations/` | die Migrationen je Release, nach `<version>/<chroot\|firstboot>/NN-name` |

## Speicher

| Pfad | Was es ist |
|---|---|
| `rpool/ROOT/os7_<version>_<zeit>` | die Bootumgebung — `/` |
| `bpool/BOOT/os7_<version>_<zeit>` | ihr `/boot` |
| `rpool/USERDATA/<benutzer>_<uuid>` | ein Home-Verzeichnis, außerhalb der Bootumgebung |
| `rpool/DATA/…` | Zustand, der einen Rollback überlebt: `log`, `spool`, `tmp`, `srv`, `lib/<dienst>`, `snapd` |
| `/dev/disk/by-partlabel/os7-luks` | der verschlüsselte Container, in dem `rpool` liegt |

## Start

| Pfad | Wozu |
|---|---|
| `/etc/grub.d/09_os7-boot-environments` | OS/7 erzeugt hier sein eigenes Bootmenü, einen Eintrag je Bootumgebung |
| `/boot/efi/…/grub.cfg` | die Datei auf der EFI-Partition, die festlegt, wessen Menü GRUB liest |
| `<bootumgebung>/boot/grub/grubenv` | `saved_entry` — welcher Eintrag darin gestartet wird |
| `/proc/cmdline` | die Kernel-Befehlszeile. `boot=zfs` muss darin stehen |

## Konfiguration

| Pfad | Wofür |
|---|---|
| `/etc/netplan/*.yaml` | die Netzwerkkonfiguration. `Get-OS7NetworkConfiguration` führt sie zusammen und nennt die Herkunft jeder Aussage |
| `/etc/chrony/sources.d/*.sources` | die NTP-Quellen. `Set-OS7TimeSynchronization` schreibt hierhin, nicht in `chrony.conf` |
| `/etc/localtime` | der Symlink, der die Zeitzone bestimmt |
| `/etc/os7/backup.json` | die Sicherungsrichtlinie. Maßgeblich; die sanoid-Konfiguration wird daraus erzeugt |
| `/etc/apt/sources.list.d/os7-release.*` | die OS/7-Paketquelle. Wird bewusst deaktiviert ausgeliefert |

## Protokolle

| Pfad | Was |
|---|---|
| `/var/log/os7-setup/install.log` | das Protokoll der Installation mit dem Selbstnachweis jedes Schrittes. Rechte `0600`, **in** der Bootumgebung. `Get-OS7InstallLog` |
| das systemd-Journal | `Get-OS7Log`. Liegt unter `/var/log`, also **außerhalb** der Bootumgebung — es überlebt den Rollback des Updates, das es erklärt |

## Programme und Module

| Pfad | Was |
|---|---|
| `/usr/lib/os7-setup/os7-setup` | der Installer. `--self-test`, `--version`, `--unattend`, `--dry-run` |
| `/usr/local/share/powershell/Modules/` | die sechs Module: `OS7`, `Zfs`, `Net`, `Time`, `Systemd`, `Directory` |
| `/usr/share/consolefonts/os7-console-16x32.psf.gz` | die Schrift der installierten Konsole (Cascadia Mono) |
| `/usr/share/consolefonts/os7-fixedsys-16x32.psf.gz` | die Schrift des Installers (Fixedsys) |
| `/etc/profile.d/95-os7-powershell.sh` | die Übergabe der Anmeldeshell an PowerShell |

## Dienste

| Unit | Wofür |
|---|---|
| `os7-update-check.timer` / `.service` | die unbeaufsichtigte Update-Prüfung |
| `os7-backup-replicate.service` | der Replikationslauf |
| `os7-migrations-firstboot.service` | die Erstmigrationen nach einem Update |
| `zfs-import-cache`, `zfs-mount`, `zfs-zed` | die ZFS-Kette beim Start |
| `chrony.service` | die Uhr |
| `authd.service` | die Anmeldung mit Entra-Konten |
