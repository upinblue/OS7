# 6 Updates

Ein Update in OS/7 ist kein Austausch von Paketen im laufenden System. Es ist
das Befüllen einer **neuen Bootumgebung** neben der laufenden, gefolgt von
einem Umschalten. Solange das Update läuft, ist die Maschine unverändert
benutzbar; geht dabei etwas schief, gibt es nichts zurückzunehmen, weil nichts
verändert wurde.

## 6.1 Was ein Release ist

OS/7 wird nicht als Strom einzelner Pakete ausgeliefert, sondern als
**kuratierte Releases**. Jedes Release ist eine vollständige Stückliste: eine
Version, ein Snapshot des Ubuntu-Archivs, gegen den es gebaut wurde, und für
jede Komponente eine Version und eine Prüfsumme. Zwei Maschinen desselben
Releases haben dieselben Pakete, unabhängig davon, wann sie installiert
wurden.

Releases kommen aus einer **signierten Paketquelle**. Die Signatur wird nicht
nur beim Herunterladen geprüft, sondern auch der Index und die Beschreibung
jedes Releases, bevor überhaupt etwas aufgelistet wird.

## 6.2 Den Kanal einstellen

Eine frisch installierte Maschine hat **keine** Update-Quelle eingetragen. Das
ist Absicht: welche Quelle eine Maschine benutzt und in welchem Tempo sie
Releases annimmt, ist eine Betriebsentscheidung.

```powershell
Set-OS7UpdateChannel -Uri https://updates.example.com/os7 -Channel stable
```

Drei Kanäle stehen zur Wahl:

| Kanal | Wofür |
|---|---|
| `stable` | der Regelbetrieb |
| `preview` | Vorabprüfung eines Releases vor der Freigabe |
| `development` | Entwicklungsstände |

Die Quelle wieder abschalten, ohne sie zu vergessen:

```powershell
Set-OS7UpdateChannel -Disable
```

## 6.3 Nachsehen, was es gibt

```powershell
Get-OS7Release
```

![Get-OS7Release listet auf, was der Kanal dieser Maschine anbietet.](images/40-get-release.png)

Mit `-Available` erscheinen nur die Releases, die neuer sind als das
installierte. `-Channel` und `-Source` fragen einen anderen Kanal oder eine
andere Quelle ab, ohne die Einstellung der Maschine zu ändern:

```powershell
Get-OS7Release -Available
Get-OS7Release -Channel preview -Source https://updates.example.com/os7
```

Bevor irgendetwas aufgelistet wird, prüft der Befehl die Signatur des Index
und den Hash jeder Release-Beschreibung. Ein Release, dessen Beschreibung
nicht zu ihrem Hash passt, erscheint nicht — es wird nicht etwa mit einer
Warnung aufgeführt.

## 6.4 Aktualisieren

```powershell
Update-OS7
```

Dieses Cmdlet braucht eine erhöhte Sitzung — siehe *Erhöhte Rechte* in Kapitel
1, dort steht auch, warum `sudo Update-OS7` nicht der Weg dorthin ist. Als
normaler Benutzer ausgeführt scheitert es in diesem Release mit einer Meldung
darüber, dass `/run/os7-update.lock` verweigert wurde — so sagt dieses Cmdlet,
dass es root braucht.

Ohne Parameter nimmt der Befehl das nächste Release des eingestellten Kanals.
Was dann passiert, in der Reihenfolge, in der es passiert:

![Die Schritte eines Updates. Die laufende Umgebung wird an keiner Stelle verändert.](images/diagram-update-de.svg)

Die wichtigen Parameter:

| Parameter | Wirkung |
|---|---|
| `-Version` | ein bestimmtes Release statt des nächsten |
| `-Channel`, `-Source` | einmalig aus einem anderen Kanal oder von einer anderen Quelle |
| `-Stage` | die neue Umgebung befüllen, aber **nicht** aktivieren |
| `-Reboot` | nach erfolgreichem Update sofort neu starten |
| `-Keep` | wie viele alte Bootumgebungen stehen bleiben |
| `-AllowDevelopment` | auch Entwicklungsstände annehmen |

Ein typischer Ablauf im Wartungsfenster:

```powershell
Update-OS7 -Stage                 # tagsüber: befüllen, nichts umschalten
# … im Fenster:
Set-OS7BootEnvironment -Name os7_1.0.1.0_202609010200
Restart-Computer
```

Oder in einem Rutsch:

```powershell
Update-OS7 -Reboot -Keep 2
```

## 6.5 Software Update, das Fenster

Auf einer Desktop-Maschine gibt es dasselbe Update als Fenster: **Apps →
System Tools → Software Update**. Es kommt aus dem Paket `os7-app-softwareupdate` und
existiert nur auf amd64-Installationen mit Desktop — auf arm64 gibt es keinen,
und eine Headless-Installation entfernt ihn.

![Software Update mit den Releases, die der Kanal anbietet.](images/app-software-update.png)

Die Liste zeigt die Releases des eingestellten Kanals, das neueste oben. Für das
ausgewählte nennt die Fläche darunter den vollständigen Release-Zeitpunkt, die
apt-Suite, den Ubuntu-Archivstand, gegen den es gebaut wurde, den Schlüssel, mit
dem es signiert ist, und wie viele Erstmigrationen es mitbringt — dieselben
Angaben, die `Get-OS7Release` ausgibt.

Die Überschrift ist einer von vier Sätzen:

| Überschrift | Was sie bedeutet |
|---|---|
| *Your software is up to date.* | im Kanal liegt nichts Neueres |
| *New software is available for your computer.* | mindestens ein Release lässt sich hier installieren |
| *New software exists, but none of it can be installed on this computer.* | es gibt neuere Releases, und jedes davon ist ausgeschlossen; jede Zeile sagt, warum |
| *This machine could not be asked about updates.* | der Kanal war nicht lesbar, die Zeile darunter nennt den Grund |

Der dritte Satz ist absichtlich ein anderer als der erste. „Es gibt nichts
Neueres" und „es gibt Neueres, das diese Maschine nicht annimmt" schicken einen
Administrator an zwei verschiedene Stellen.

Ein Release, das hier nicht installierbar ist, bekommt trotzdem eine Zeile — mit
abgeschaltetem Kontrollkästchen und dem Grund in der Fläche: es ist für eine
andere Architektur gebaut, es ist nicht neuer als das laufende Release, es ist
ein Hotfix für ein Release, das diese Maschine nicht hat (dann erst auf jenes
aktualisieren), oder es überschreitet eine Hauptversion — und das ist eine
Installation und kein Update.

**Das Fenster entscheidet nichts davon.** Ob ein Release anwendbar ist, wird bei
`Get-OS7Release` GELESEN und nie nachgerechnet; Fenster und Cmdlet können sich
über dasselbe Release also nicht widersprechen. Die Hauptschaltfläche zählt,
was sie tun wird — mit einem angehakten Release steht dort *Install 1 Item* —
und startet `os7-update@<version>.service`; polkit fragt zuerst nach einem
Administratorkennwort und nennt dabei, wofür, und systemd führt dann
`Update-OS7` als root aus. Die Anwendung selbst hat diese Rechte nie. Alles aus
6.4 gilt, denn unter dem Fenster liegt derselbe Code — einschließlich des
Neustarts, den das Fenster nennt, bevor es etwas beginnt.

**Ein Release, das nicht für die Produktion signiert ist, wird hier abgelehnt**,
und die Zeile sagt es mit dem Schlüssel, der es signiert hat. Nur das Cmdlet
nimmt ein solches Release an:

```powershell
sudo pwsh -c 'Update-OS7 -Version 1.0.0.246 -AllowDevelopment'
```

Genau diesen Satz gibt die Zeile selbst aus, mit eingesetzter Version. Solange
ein Release nicht unter dem Produktionsschlüssel veröffentlicht ist, zeigt eine
Maschine, der es angeboten wird, es in der Liste an und installiert es von dort
nicht.

## 6.6 Nach dem Neustart

Beim ersten Start der neuen Umgebung laufen die **Erstmigrationen** des
Releases. Das sind die Schritte, die sich nur auf einer laufenden Maschine
erledigen lassen — etwa das Neuversiegeln des TPM-Schlüssels gegen die
tatsächliche Startkette.

Danach prüfen Sie das Ergebnis:

```powershell
Get-OS7Version
Get-OS7BootEnvironment | Format-Table Name, Active, Running, Menu, Release
Get-OS7Service -Detailed | ? { $_.Healthy -eq $false }
```

Passt etwas nicht, geht es mit einem Befehl zurück:

```powershell
Restore-OS7
```

## 6.7 Die Entscheidungen prüfen, ohne zu aktualisieren

`Test-OS7Update` prüft die Logik des Update-Weges auf dieser Maschine — ohne
Paketquelle, ohne ZFS-Änderungen und ohne Neustart:

![Test-OS7Update prüft die Entscheidungen des Update-Weges auf dieser Maschine.](images/41-test-update.png)

Das ist der Befehl für die Frage „ist mit dieser Maschine grundsätzlich alles
in Ordnung", bevor man ein Update anstößt.

## 6.8 Unbeaufsichtigt prüfen

OS/7 bringt einen Zeitgeber mit, der regelmäßig nachsieht, ob der Kanal etwas
Neues hat:

Der Zeitgeber heißt `os7-update-check.timer`, und er ist eine *geplante
Aufgabe* — dieselbe Unterscheidung, die Windows zwischen einem Dienst und
einer Aufgabe in der Aufgabenplanung macht. Kapitel 9.5 zeigt die ganze
Oberfläche; der eine Befehl, der hier zählt:

```powershell
Get-OS7ScheduledTask os7-update-check.timer
```

![Die unbeaufsichtigte Update-Prüfung, als geplante Aufgabe.](images/43-update-timer.png)

`NextRun` beantwortet die Frage „bleibt diese Flotte aktuell, ohne dass jemand
etwas tippt": ein Datum heißt ja, ein leeres Feld heißt, der Zeitgeber ist
nicht scharf — und `Healthy` sagt es dazu.

Die Prüfung hat einen festen Vertrag über ihren Rückgabewert, und der ist
genau das, was eine Überwachung auswertet:

| Rückgabewert | Bedeutung |
|---|---|
| `0` | nichts zu tun — oder kein Kanal eingestellt |
| `2` | ein Update wurde vorbereitet und wartet auf das Umschalten |
| `1` | die Prüfung ist fehlgeschlagen |

Ein- und ausschalten:

```powershell
Enable-OS7ScheduledTask  os7-update-check.timer
Disable-OS7ScheduledTask os7-update-check.timer
```

## 6.9 Was ein Update mitnimmt und was nicht

Die Aufteilung aus Kapitel 3 entscheidet, und sie lohnt die Wiederholung, weil
sie das ganze Verfahren erklärt:

**Rollt mit:** das System selbst — `/`, `/usr`, `/etc`, die Paketdatenbank
unter `/var/lib/dpkg` und `/var/lib/apt`, der Paketzwischenspeicher, der
Kernel und das initramfs.

**Rollt nicht mit:** die Home-Verzeichnisse, `/var/log`, `/var/spool`,
`/var/tmp`, `/srv`, die Datenverzeichnisse der Dienste unter `/var/lib/<dienst>`
und der Zustand der Verwaltungsagenten.

Der letzte Punkt ist der wichtigste und der am wenigsten offensichtliche.
Entra, Intune und Arc halten das andere Ende einer Geräteidentität — mit
Registrierungen, Zertifikaten, die eigenen Zeitplänen folgen, und
Konformitätszuständen. Der Mandant rollt nicht zurück. Eine Maschine, die aus
einem Rollback mit einer veralteten Identität zurückkäme, wäre ein Problem im
Mandanten und nicht auf dem Gerät — und damit vom Gerät aus unsichtbar.
Deshalb liegt dieser Zustand außerhalb der Bootumgebung.
