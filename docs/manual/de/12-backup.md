# 12 Sicherung und Wiederherstellung

Die Sicherung von OS/7 besteht aus zwei Teilen, und die Trennung erklärt das
ganze Kapitel:

* **Snapshots auf dieser Maschine** schützen vor Fehlern — versehentlich
  gelöscht, falsch überschrieben, eine Migration, die schiefging. Sie kosten
  fast nichts und sind sofort verfügbar.
* **Replikation auf ein Ziel** schützt vor dem Verlust der Maschine. Sie
  braucht ein zweites Medium und Zeit.

Snapshots sind standardmäßig eingeschaltet, Replikation ist eine bewusste
Entscheidung.

![Die Sicherungsarchitektur: sanoid schnappschusst, syncoid repliziert, und OS/7 prüft nach — bei ZFS, nicht bei den Werkzeugen.](images/diagram-backup-de.svg)

> **Warum OS/7 nachprüft.** Beide Werkzeuge melden in bestimmten Fällen Erfolg,
> obwohl nichts passiert ist: sanoid beendet sich mit 0, auch wenn das Anlegen
> eines Snapshots scheiterte, und seine eigene Überwachung antwortet aus einem
> Zwischenspeicher, der absichtlich bis zu fünf Stunden alt sein darf. Deshalb
> fragt `Get-OS7BackupStatus` **ZFS** — auf der Quelle und über SSH auf dem
> Ziel — und keines der beiden Werkzeuge.

## 12.1 Die Richtlinie ansehen

```powershell
Get-OS7BackupPolicy | Format-List
```

![Was diese Maschine schnappschusst und wie lange sie es behält.](images/90-backup-policy.png)

Die Einzelheiten je Dataset:

```powershell
(Get-OS7BackupPolicy).Sources | Format-Table Dataset, Snapshots, Newest
```

Die Richtlinie steht in `/etc/os7/backup.json`. Das ist die maßgebliche Datei;
die Konfiguration für sanoid wird daraus erzeugt — und von sanoid selbst
geprüft, bevor sie installiert wird.

## 12.2 Die Richtlinie ändern

Welche Datasets gesichert werden:

```powershell
Set-OS7BackupPolicy -Dataset rpool/USERDATA, rpool/DATA/srv
```

Wie lange die Snapshots behalten werden:

```powershell
Set-OS7BackupPolicy -Retention @{ hourly = 48; daily = 30; weekly = 8; monthly = 12 }
```

Ein- und ausschalten:

```powershell
Enable-OS7Backup
Disable-OS7Backup
```

Das Ausschalten **zerstört nichts**. Vorhandene Snapshots bleiben; es werden
nur keine neuen mehr angelegt und keine alten mehr entfernt.

> **`rpool/ROOT` und `bpool/BOOT` gehören nicht in die Richtlinie.** Diese
> Datasets gehören dem Bootumgebungs-Mechanismus. Der Versuch wird abgewiesen
> — hier wäre eine zweite Instanz, die Snapshots anlegt und aufräumt, dem
> Rollback im Weg.

## 12.3 Was die Richtlinie erreicht

Eine Richtlinie, die ein Home-Verzeichnis nennt, das gar nicht auf einem
eigenen Dataset liegt, sichert dieses Home nicht — sie sichert nichts, was
danach benannt wäre, und sagt es nicht von selbst:

```powershell
Get-OS7BackupCoverage | Format-List
```

![Welche Home-Verzeichnisse die Richtlinie tatsächlich erreicht — und bei welchen nicht, warum.](images/91-backup-coverage.png)

Nur das, was nicht abgedeckt ist:

```powershell
Get-OS7BackupCoverage | Where-Object { -not $_.Covered }
```

Das ist die Ergänzung zu `Get-OS7Home` aus Kapitel 4.4: Dort ging es darum, ob
ein Home auf einem eigenen Dataset liegt; hier darum, ob die Sicherung es
erreicht. Ein Home ohne eigenes Dataset kann von keiner Snapshot-Richtlinie
erfasst werden.

## 12.4 Ein Ziel einrichten

**Eine externe Platte**, die von OS/7 eingerichtet wird:

```powershell
$pw = Read-Host -AsSecureString -Prompt 'Passphrase für die Sicherungsplatte'
New-OS7BackupTarget -Name usb `
    -CreateOn /dev/disk/by-id/usb-Samsung_T7_0001 `
    -ConfirmDisk /dev/disk/by-id/usb-Samsung_T7_0001 `
    -Passphrase $pw
```

> **`-ConfirmDisk` ist keine Rückfrage, sondern ein zweites Nennen.** Dieser
> Befehl **löscht die genannte Platte**. Wer sie ein zweites Mal eintippen
> muss, tippt keine falsche — eine Ja-Nein-Rückfrage bestätigt dagegen nur,
> dass man den Befehl abgeschickt hat.

**Ein Pool auf einem anderen Rechner**, über SSH:

```powershell
New-OS7BackupTarget -Name nas -ComputerName backup@nas.lan -Dataset tank/os7
```

**Ein bereits vorhandener lokaler Pool:**

```powershell
New-OS7BackupTarget -Name zweitpool -Pool tank -Dataset tank/os7
```

Ziele ansehen und prüfen:

```powershell
Get-OS7BackupTarget | Format-Table Name, Kind, Present, InSync, NewestReplicated
Test-OS7BackupTarget usb
```

Eine Wechselplatte ein- und aushängen:

```powershell
Mount-OS7BackupTarget usb -Passphrase $pw
# … Replikation …
Dismount-OS7BackupTarget usb
```

`Dismount-` exportiert den Pool und schließt den LUKS-Container, damit die
Platte gefahrlos abgezogen werden kann.

## 12.5 Sichern

Snapshots laufen nach Zeitplan. Von Hand anstoßen:

```powershell
Start-OS7Backup                       # nur Snapshots
Start-OS7Backup -Replicate            # Snapshots und danach replizieren
Start-OS7BackupReplication -Target nas   # nur replizieren, nur dieses Ziel
```

Die Replikation nimmt eine Sperre, weil syncoid selbst keine hat — zwei
gleichzeitig laufende Läufe auf dieselbe Quelle wären ein Problem.

## 12.6 Ist es wirklich gesichert

```powershell
Get-OS7BackupStatus | Format-List
```

Der Befehl fragt ZFS auf der Quelle und, über die ZFS-Schicht per SSH, auf dem
Ziel — und vergleicht die **GUIDs** der Snapshots. Nicht die Namen: zwei
Snapshots gleichen Namens sind nicht dasselbe Objekt, und ein Namensvergleich
würde eine unterbrochene Replikationskette für in Ordnung halten.

`-SkipTargets` beschränkt die Antwort auf die lokale Seite; das ist schnell und
braucht kein erreichbares Ziel.

Für die Überwachung:

```powershell
Get-OS7BackupStatus | ConvertTo-Json -Depth 6
```

## 12.7 Eine Datei zurückholen

Der häufigste Fall überhaupt: eine einzelne Datei von gestern.

```powershell
Get-OS7FileVersion /home/mmustermann/angebot.docx
```

Der Befehl geht die Snapshots durch und listet jede Fassung, die noch
vorhanden ist, mit Zeitpunkt und Größe. `-DistinctOnly` blendet
aufeinanderfolgende identische Fassungen aus, `-Newest` beschränkt die Anzahl,
`-IncludeCurrent` nimmt die aktuelle Datei mit in den Vergleich auf.

Zurückholen:

```powershell
# die Fassung von gestern 18 Uhr, an den ursprünglichen Ort
Restore-OS7File /home/mmustermann/angebot.docx -AsOf '2026-08-28 18:00'

# eine bestimmte Fassung, woandershin — sicherer, weil nichts überschrieben wird
Restore-OS7File /home/mmustermann/angebot.docx `
    -Snapshot autosnap_2026-08-28_18:00:01_hourly `
    -Destination /home/mmustermann/angebot-alt.docx
```

Ohne `-Destination` wird die vorhandene Datei ersetzt, und dafür verlangt der
Befehl `-Force`.

> Ein Benutzer, dem die Datei gehört, braucht dafür keinen Administrator:
> Snapshots sind für ihn lesbar, und `Get-OS7FileVersion` läuft ohne erhöhte
> Rechte.
