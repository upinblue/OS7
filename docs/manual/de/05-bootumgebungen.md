# 5 Bootumgebungen und Rollback

Eine **Bootumgebung** ist ein vollständiges, startfähiges System auf demselben
Datenträger. Eine Maschine kann mehrere davon haben, startet aber immer genau
eine. Sie ist das Werkzeug, das aus einem Update etwas macht, das man
rückgängig machen kann.

Der Gedanke ist einfach: Statt das laufende System zu verändern, legt OS/7
eine Kopie an, verändert die Kopie und schaltet danach um. Weil ZFS mit
Copy-on-Write arbeitet, kostet die Kopie zunächst fast nichts — sie wächst nur
um die Unterschiede.

## 5.1 Was da ist

```powershell
Get-OS7BootEnvironment
```

![Die Bootumgebungen der Maschine. Die Standardausgabe ist eine Liste je Umgebung.](images/30-boot-environments.png)

Die Felder sagen jeweils etwas anderes, und die Unterschiede sind wichtig:

| Feld | Bedeutung |
|---|---|
| `Active` | ZFS hat diese Umgebung **irgendwo** eingehängt |
| `Running` | **aus dieser Umgebung läuft das System gerade** |
| `Menu` | sie hat einen Eintrag im Startmenü |
| `Complete` | ihre beiden Hälften — `rpool/ROOT` und `bpool/BOOT` — sind beide da |
| `Release` | welche OS/7-Version darin steckt |
| `RootDataset`, `BootDataset` | die beiden Datasets, aus denen sie besteht |
| `Origin` | der Snapshot, aus dem sie geklont wurde — bei der installierten Umgebung leer |

> **`Active` heißt nicht „läuft".** Ein Update hängt den Klon ein, um ihn zu
> befüllen — in diesem Moment sind zwei Umgebungen `Active`, und nur eine ist
> `Running`. Alles, was „das laufende System" meint, liest `Running`.

Für eine Übersicht über viele Umgebungen ist eine Tabelle handlicher:

```powershell
Get-OS7BootEnvironment | Format-Table Name,Active,Running,Menu,Release
```

## 5.2 Was entscheidet, was startet

Drei Dinge, und **keines davon ist eine ZFS-Eigenschaft**:

![Die drei Stellen, die zusammen bestimmen, welche Bootumgebung startet.](images/diagram-boot-environments-de.svg)

1. **OS/7 schreibt sein eigenes Bootmenü**
   (`/etc/grub.d/09_os7-boot-environments`), mit einem Eintrag je Umgebung.
   Die Menügeneratoren, die Ubuntu mitbringt, führen genau eine Umgebung je
   Maschine auf; ein Menü, das aus einer Umgebung erzeugt wird, kann eine
   zweite nie enthalten.
2. **Eine Datei auf der EFI-Partition** legt fest, wessen Menü GRUB überhaupt
   liest (`set prefix=($root)'/BOOT/<umgebung>@/grub'`).
3. **`saved_entry`** in der `grubenv` dieser Umgebung benennt den Eintrag
   darin.

Praktisch heißt das: Umschalten ist eine **Bootloader-Operation**, keine
ZFS-Operation. Wer eine Bootumgebung aktiviert, verändert Dateien auf der
EFI-Partition und im Bootpool — und nicht eine Eigenschaft eines Datasets.

## 5.3 Eine Bootumgebung anlegen

Vor einem riskanten Eingriff — einer Konfigurationsänderung, die man notfalls
zurücknehmen will — legt man eine Umgebung an, ohne sie zu aktivieren:

```powershell
New-OS7BootEnvironment -Name demo
```

![Das Anlegen zeigt jeden Schritt: erst Snapshots beider Hälften, dann die Klone, dann das Ergebnis.](images/32-new-be.png)

Die Ausgabe ist absichtlich gesprächig. Was Sie sehen, ist die vollständige
Arbeit: ein Snapshot der Wurzel und des Bootpools, dann ein Klon je Dataset —
einschließlich der `var`-Kinder, die zur Bootumgebung gehören — und am Ende
das Ergebnisobjekt. `Active` und `Running` stehen auf `False`: die neue
Umgebung existiert, ist aber nirgends eingehängt und startet nicht.

Die neue Umgebung erscheint jetzt in der Liste:

```powershell
Get-OS7BootEnvironment
```

![Zwei Bootumgebungen. Die neue hat noch keinen Menüeintrag.](images/33-be-after-new.png)

Mit `-From` klont man nicht die laufende Umgebung, sondern eine andere; mit
`-Release` gibt man ihr eine Versionsbezeichnung mit.

## 5.4 Umschalten

```powershell
Set-OS7BootEnvironment -Name demo
```

Das erzeugt den Menüeintrag, setzt den EFI-Zeiger und schreibt `saved_entry`.
Nach dem nächsten Neustart läuft die Maschine aus dieser Umgebung.

> **Es gibt keinen einmaligen Start „nur zum Ausprobieren".** Eine Umgebung,
> die gestartet wird, ohne aktiviert zu sein, bekommt das `/boot` und die
> Paketdatenbank der **aktivierten** Umgebung — ein halb umgeschaltetes Paar,
> das kein Werkzeug erkennt. Umschalten ist der einzige unterstützte Weg, und
> es ist umkehrbar; genau dafür gibt es `Restore-OS7`.

## 5.5 Zurückrollen

Der Weg zurück nach einem Update, das nicht getaugt hat:

```powershell
Restore-OS7
```

Ohne Parameter geht das auf die vorhergehende Umgebung zurück — die, aus der
die laufende hervorgegangen ist. Mit `-BootEnvironment` benennt man eine
bestimmte:

```powershell
Restore-OS7 -BootEnvironment os7_1.0.0.159_202608300312
```

`Restore-OS7` schaltet um, mehr nicht. Die Daten des Benutzers, die
Protokolle, die Zustände der Dienste und alles unter `rpool/DATA` und
`rpool/USERDATA` bleiben, wo sie sind — sie liegen außerhalb der Bootumgebung
und rollen nicht mit. Zurückgenommen wird das System: `/`, `/usr`, `/etc`,
die Paketdatenbank und der Kernel.

Nach dem Neustart lohnt eine Kontrolle:

```powershell
Get-OS7BootEnvironment | Format-Table Name, Active, Running, Menu
Get-OS7Version
```

## 5.6 Aufräumen

Bootumgebungen belegen mit der Zeit Platz, weil sie die Unterschiede zu ihrem
Ursprung festhalten. Eine nicht mehr gebrauchte entfernt man mit:

```powershell
Remove-OS7BootEnvironment -Name demo -Confirm:$false
```

![Das Entfernen räumt beide Hälften weg — die Wurzel und den Bootpool.](images/34-remove-be.png)

Der Befehl fragt vorher nach; in einem Skript unterdrückt man die Rückfrage
mit `-Confirm:$false`. Beide Hälften werden entfernt — eine Umgebung, von der
nur noch der Bootpool-Teil übrig ist, wäre ein Eintrag im Menü, der ins Leere
führt.

Die laufende und die aktive Umgebung lassen sich nicht entfernen.

`Update-OS7` räumt selbständig auf: Der Parameter `-Keep` bestimmt, wie viele
alte Umgebungen nach einem erfolgreichen Update stehen bleiben.

## 5.7 Wenn eine Maschine nicht mehr startet

Das Bootmenü enthält einen Eintrag je vollständiger Bootumgebung. Startet die
Maschine nach einem Update nicht mehr, wählt man im Menü den Eintrag der
vorigen Umgebung aus — die Maschine kommt hoch, und danach macht man das
Umschalten mit `Restore-OS7` dauerhaft.

Das ist der Grund, warum OS/7 sein Menü selbst schreibt und warum ein Eintrag
je Umgebung darin steht: Der Weg zurück muss auch dann funktionieren, wenn auf
der Maschine gerade gar nichts mehr läuft, in dem man einen Befehl eintippen
könnte.
