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

Welche Datasets gesichert werden. **Der Befehl ersetzt die Liste, er ergänzt
sie nicht** — nennen Sie jedes Dataset, das gesichert werden soll, auch die
bereits vorhandenen:

```powershell
Set-OS7BackupPolicy -Dataset rpool/USERDATA, rpool/DATA/srv, rpool/DATA/lib/os7-domain-homes
```

Das ist die Standardliste. `rpool/USERDATA` enthält die Benutzerverzeichnisse
lokaler Konten, je eines pro Konto; `rpool/DATA/lib/os7-domain-homes` enthält
die Benutzerverzeichnisse der Konten, die sich aus der Domäne anmelden. Lässt
man das dritte weg, bewahrt die Maschine für Domänenbenutzer nichts mehr auf —
keine Snapshots, keine Sicherung und keine früheren Versionen ihrer Dateien.

`Get-OS7BackupPolicy` zeigt die geltende Liste, bevor Sie sie ändern.

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

**Was da war, wird aufbewahrt — ein Zurückholen lässt sich also selbst
rückgängig machen.** Bevor etwas überschrieben wird, bewahrt die Maschine den
aktuellen Stand mit dem stärksten Mittel, das ihr an dieser Stelle zur Verfügung
steht, und die Rückfrage sagt es, bevor Sie antworten:

* als **root** ein ZFS-Snapshot des Ziel-Datasets, benannt
  `os7-before-restore-<Datum>-<Zeit>`. Das Ergebnis nennt ihn in
  `SafetySnapshot`, und `Restore-OS7File -Snapshot <dieser Name> -Force` stellt
  den vorherigen Zustand wieder her.
* als **Eigentümer der Datei** die vorhandene Datei, **umbenannt** in
  `<Datei>.os7-before-restore-<Datum>-<Zeit>`, im selben Verzeichnis daneben.
  Das Ergebnis nennt sie in `SafetyCopy`. Das Umbenennen kostet keinen
  Plattenplatz, und es ist sichtbar: Sie entscheiden, wann die Datei erledigt
  ist, und niemand löscht sie für Sie.

`-NoSafetyPoint` schaltet beides ab. Liegt das Ziel gar nicht auf ZFS — ein
USB-Stick, eine Netzwerkfreigabe —, wird trotzdem zurückgeholt, und Sie erfahren,
dass es sich nicht rückgängig machen lässt.

> Ein Benutzer, dem die Datei gehört, braucht dafür keinen Administrator:
> Snapshots sind für ihn lesbar, und `Get-OS7FileVersion` läuft ohne erhöhte
> Rechte.

**„has NO snapshots at all" heißt nicht „die Datei hat sich nie geändert".**
Antwortet der Befehl

```
rpool/DATA/tmp has NO snapshots at all, so nothing on this machine holds an
earlier version of '/var/tmp/bericht.txt'...
```

dann bewahrt dieses Dataset überhaupt keine Historie auf — entweder steht es
nicht in der Sicherungsrichtlinie (`Get-OS7BackupPolicy` zeigt, welche Datasets
darin stehen, `Set-OS7BackupPolicy` nimmt eines auf, §12.2), oder die Maschine
wurde vor wenigen Minuten installiert und hat ihren ersten Snapshot noch nicht
genommen. Standardmäßig werden nur `rpool/USERDATA`, `rpool/DATA/srv` und
`rpool/DATA/lib/os7-domain-homes` gesichert; `/var/log`, `/var/tmp` und
Wechselmedien nicht.

## 12.8 Vorgängerversionen, das Fenster

Auf einer Desktop-Maschine gibt es dieselbe Historie im Dateimanager. Ein
Rechtsklick auf eine Datei in **Dateien**, dann **Versions**:

![Das Kontextmenü in Dateien. Der Eintrag wird für jede lokale Datei angeboten.](images/app-versions-menu.png)

Es kommt aus dem Paket `os7-app-versions` und existiert nur auf
amd64-Installationen mit Desktop. Einen Eintrag im Startmenü gibt es
absichtlich nicht: die Anwendung ist eine Frage nach *einer Datei* und braucht
einen Pfad — ein Menüeintrag könnte nur ein Fenster öffnen, das „nennen Sie eine
Datei" sagt. Der zweite Weg hinein ist *Öffnen mit*, und der hält die Tür auch
für einen Dateimanager offen, den OS/7 noch nicht kennt.

![Die Versionen einer Datei, die neueste vorn.](images/app-versions.png)

Die Überschrift ist der Name der Datei, und die Zeile darunter sagt, was die
Historie abdeckt — *„6 versions, back to 2026-09-22"* —, denn wer entscheidet,
ob er weitersuchen muss, braucht den Zeitraum und nicht die Anzahl. Jede Karte
trägt ihren Zeitpunkt, ihre Größe und die Aufbewahrungsstufe, die sie hält:
*kept as: hourly*, *daily*, *weekly*, *monthly* — und *live* für die Datei, wie
sie jetzt ist. Das sind sanoids eigene Stufen, aus dem Namen des Snapshots
gelesen und nicht hier ausgerechnet. Eine Textdatei wird in der Karte
angezeigt; bei allem anderen steht es da, mit dem Verweis auf **Open**.

Drei Schaltflächen wirken auf die ausgewählte Version, und der Unterschied
zwischen ihnen ist der Punkt:

| Schaltfläche | Was sie tut |
|---|---|
| **Open** | öffnet diese Version nur zum Lesen. Ändert nichts |
| **Copy to…** | schreibt diese Version woandershin, unter einem Namen Ihrer Wahl. Ändert nichts |
| **Restore…** | ersetzt die aktuelle Datei durch diese Version. Fragt vorher |

*Restore…* nennt die Datei und den Zeitpunkt der Version in der Frage, bevor sie
beantwortet wird, und sagt, dass das Vorhandene zuerst aufbewahrt wird:

![Die Rückfrage nennt, was ersetzt werden soll.](images/app-versions-restore.png)

**Das Fenster entscheidet nichts, was 12.7 nicht schon entschieden hat.** Es
ruft `Get-OS7FileVersion` für das, was es zeigt, und `Restore-OS7File`, um eine
Version zurückzuholen; das Zurückholen ist das des Cmdlets und keine zweite
Umsetzung davon. (*Copy to…* schreibt die Datei selbst — deshalb steht es in
einer anderen Zeile der Tabelle oben: eine Version unter einem selbstgewählten
Namen zu kopieren rührt an nichts, was die Maschine aufbewahrt, und braucht
keine Regel.) Also gilt hier dieselbe Sicherungsregel wie oben: vom
Eigentümer der Datei ausgeführt wird die ersetzte Datei in
`<Datei>.os7-before-restore-<Datum>-<Zeit>` **umbenannt** und bleibt im selben
Verzeichnis. Sie ist sichtbar, sie kostet keinen Plattenplatz, und niemand
entfernt sie von selbst:

```powershell
# in einer erhöhten Sitzung — die Liste der Datasets kommt aus
# /etc/os7/backup.json, und die liest nur root
Get-OS7RestoreAside | Format-Table Path, Length, PutAside, Held

# oder das Dataset benennen, dann braucht es keine erhöhten Rechte
Get-OS7RestoreAside -Dataset rpool/USERDATA/mmustermann_0f855748
```

`Held` wird ZFS für jede Datei einzeln gefragt und nicht aus ihrem Alter
geschlossen: es sagt, ob ein Snapshot diesen Inhalt noch hält — und nur das
macht das Löschen der Datei daneben unbedenklich. Eine vor Minuten beiseite
gelegte Datei steht auf `False` — das ändert erst der nächste Snapshot.

**Bei einer Datei, für deren Dataset nichts aufbewahrt wird, lautet die
Überschrift *Previous versions could not be listed.*** Fehlgeschlagen ist
nichts. Der Satz in der Mitte des Fensters ist der des Cmdlets — der oben
zitierte, der das Dataset nennt und sagt, was zu tun ist —, und dieser Satz ist
der, auf den es ankommt. `/var/log`, `/var/tmp` und alles außerhalb der
Sicherungsrichtlinie sind in diesem Zustand.
