# 4 Speicher und Dateisystem

Das Dateisystem von OS/7 ist **ZFS**. Wer aus der Windows-Welt kommt, kann es
sich als Kombination aus Datenträgerverwaltung, Dateisystem, Volumenschatten­
kopien und Software-RAID vorstellen — nur dass alles davon von derselben
Schicht verwaltet wird und alles davon jederzeit auf Konsistenz prüfbar ist.

Zwei Begriffe reichen für den Anfang:

* Ein **Pool** ist die Zusammenfassung der Datenträger. OS/7 legt zwei an:
  `bpool` für das, was GRUB lesen muss, und `rpool` für alles andere.
* Ein **Dataset** ist ein Dateisystem im Pool. Datasets teilen sich den freien
  Platz des Pools, haben aber je eigene Eigenschaften, eigene Snapshots und
  einen eigenen Einhängepunkt. Wo Windows eine Partition anlegen würde, legt
  ZFS ein Dataset an — ohne feste Größe und ohne Neuformatieren.

## 4.1 Die Pools ansehen

```powershell
Get-Zpool | Format-Table Name,Health,Size,Free
```

![Die beiden Pools einer OS/7-Maschine.](images/20-get-zpool.png)

`Health` ist die Frage, die zählt. `ONLINE` ist gut; alles andere ist ein
Grund, weiterzuschauen:

```powershell
Get-ZpoolStatus rpool | Format-List Name,State,Scan
```

![Der Zustand eines Pools, mit der letzten Prüfung.](images/21-zpool-status.png)

`Get-ZpoolStatus` liefert den vdev-Baum als **Objekte**, nicht als eingerückten
Text. Man kann also darüber laufen, statt ihn zu lesen:

```powershell
(Get-ZpoolStatus rpool).Vdevs | Where-Object { $_.State -ne 'ONLINE' }
```

Eine regelmäßige Vollprüfung des Pools startet man mit:

```powershell
Start-ZpoolScrub rpool
```

Sie läuft im Hintergrund und beeinträchtigt den Betrieb kaum; der Fortschritt
steht im `Scan`-Feld von `Get-ZpoolStatus`.

## 4.2 Die Datasets

```powershell
Get-ZfsDataset | Format-Table Name,Mountpoint
```

![Die Dataset-Aufteilung einer installierten Maschine. Die Struktur ist die aus Kapitel 3.](images/22-datasets.png)

An dieser Ausgabe kann man die Aufteilung ablesen, die Kapitel 3 gezeichnet
hat:

| Was Sie sehen | Was es bedeutet |
|---|---|
| `rpool/ROOT/os7_<version>_<zeit>` | die Bootumgebung — das System selbst |
| `rpool/ROOT/…/var/lib/dpkg`, `…/var/lib/apt`, `…/var/cache` | die Paketdatenbank, **in** der Bootumgebung |
| `rpool/DATA/log`, `…/spool`, `…/tmp`, `…/srv`, `…/lib/<dienst>` | Zustand **außerhalb** der Bootumgebung |
| `rpool/USERDATA/<benutzer>_<uuid>` | ein Home-Verzeichnis, außerhalb der Bootumgebung |
| `bpool/BOOT/os7_<version>_<zeit>` | Kernel und initramfs dieser Bootumgebung |

Größen kommen als **Bytes vom Typ `uint64`**, Zeitstempel als `[datetime]`. Man
kann also rechnen und sortieren, ohne zu parsen:

```powershell
Get-ZfsDataset | Sort-Object Used -Descending | Select-Object -First 5 Name,
    @{ n = 'Belegt'; e = { Format-ZfsSize $_.Used } }
```

## 4.3 Wo der Platz geblieben ist

Die Frage „warum ist der Pool voll" beantwortet ZFS anders als ein
gewöhnliches Dateisystem, weil Snapshots Platz belegen, den keine sichtbare
Datei mehr braucht:

```powershell
Get-ZfsSpace rpool | Format-List
```

![Die Aufschlüsselung des belegten Platzes.](images/23-space.png)

Die Felder trennen, was die Daten selbst belegen, was **Snapshots** festhalten
und was für Kinder-Datasets reserviert ist. Ein Pool, der voll ist, obwohl
nichts darin liegt, hält seinen Platz in Snapshots — und die kommen entweder
von der Sicherungsrichtlinie (Kapitel 12) oder von alten Bootumgebungen
(Kapitel 5).

## 4.4 Home-Verzeichnisse

Jedes Home-Verzeichnis soll auf einem eigenen Dataset unterhalb von
`rpool/USERDATA` liegen. Das ist keine Ordnungsfrage: liegt ein Home
**innerhalb** der Bootumgebung, dann nimmt ein Rollback die Dateien des
Benutzers mit zurück, und keine Snapshot-Richtlinie kann ihm folgen.

```powershell
Get-OS7Home | Format-List
```

![Für jedes Home-Verzeichnis: hat es ein eigenes Dataset, liegt es tatsächlich dort, und stimmen beide Aussagen überein.](images/24-home.png)

Die Spalten sind so gewählt, dass man den Fehler sieht und nicht nur den
Sollzustand:

| Spalte | Frage |
|---|---|
| `Dataset` | welches Dataset für dieses Home vorgesehen ist |
| `OwnDataset` | ob es dieses Dataset gibt |
| `OwnFilesystem` | ob das Home tatsächlich auf einem eigenen Dateisystem liegt |
| `Agrees` | ob beides dasselbe sagt |
| `DeviceId` | die Kennung des Dateisystems, aus der das abgeleitet wurde |

`Agrees = False` ist genau der Fall, den die Spalte finden soll: ein Dataset ist
da, aber das Home liegt woanders.

Ein Home nachträglich auf ein eigenes Dataset umziehen:

```powershell
Move-OS7Home -UserName maier
```

Der Umzug legt das Dataset an, kopiert den Inhalt, prüft ihn nach und hängt
ihn um. Das Original bleibt zunächst liegen; erst `-RemoveOriginal` entfernt
es, und das erst, nachdem die Prüfung bestanden ist.

## 4.5 Snapshots von Hand

Die Sicherungsrichtlinie in Kapitel 12 nimmt Snapshots nach Zeitplan. Vor einem
größeren Eingriff nimmt man auch gern einen von Hand:

```powershell
New-ZfsSnapshot -Name rpool/USERDATA/maier_1a2b3c4d -SnapshotName vor-migration
Get-ZfsSnapshot | Where-Object Name -like '*@vor-migration'
```

Snapshots kosten zunächst nichts und wachsen nur um das, was sich danach
ändert. Ein einzelne Datei holt man aus einem Snapshot mit `Restore-OS7File`
zurück (Kapitel 12.6), ohne das ganze Dataset anzufassen.

> **Vorsicht.** `Restore-ZfsSnapshot` rollt ein **ganzes Dataset** auf den
> Stand des Snapshots zurück und verwirft alles Neuere unwiderruflich. Für
> „ich brauche nur diese eine Datei von gestern" ist `Restore-OS7File` das
> richtige Werkzeug.

## 4.6 Was man nicht tun sollte

**Keine Auslagerungsdatei auf ZFS.** Die Kombination führt unter Speicherdruck
zu Verklemmungen. OS/7 legt die Auslagerung auf zram, komprimiert im
Arbeitsspeicher.

**Keine Snapshot-Richtlinie auf `rpool/ROOT` oder `bpool/BOOT`.** Diese
Datasets gehören dem Bootumgebungs-Mechanismus; eine zweite Instanz, die dort
Snapshots anlegt und wieder wegräumt, gerät ihm in die Quere.
`Assert-OS7DatasetSafe` hält das auch dann fest, wenn es jemand versucht.

**Datasets nicht mit `zfs` von Hand anlegen, wenn ein Cmdlet dafür da ist.**
`New-OS7Storage` und `New-OS7BootEnvironment` setzen Eigenschaften, die ein
Klon nicht erbt — `canmount` und `mountpoint` insbesondere. Ein von Hand
angelegter Klon kommt als `canmount=on mountpoint=none` heraus: er lässt sich
über das laufende System einhängen und taucht in keinem Bootmenü auf.
