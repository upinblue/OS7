# 2 Erste Schritte

## 2.1 Anmelden

Eine OS/7-Maschine ohne Desktop begrüßt Sie an der Konsole mit einem
Anmeldebildschirm, der die Version der Maschine nennt. Nach der Anmeldung
erscheint eine Begrüßung und danach **direkt eine PowerShell-Eingabeaufforderung**.

![Die Konsole nach der Anmeldung: /etc/issue nennt die Version, die Begrüßung folgt, und die Anmeldung landet in PowerShell — nicht in einer bash-Eingabezeile.](images/00-login.png)

Das gilt für alle drei Wege auf die Maschine:

| Weg | Wo Sie landen |
|---|---|
| Konsole (Bildschirm oder serielle Schnittstelle) | PowerShell |
| `ssh benutzer@maschine` (interaktiv) | PowerShell |
| `ssh benutzer@maschine 'befehl'` | **bash** |
| Terminalfenster auf dem Desktop | PowerShell |

Die dritte Zeile ist wichtig und ist Absicht. Ein nicht-interaktiver
SSH-Aufruf bleibt in `bash`, weil `scp`, `rsync`, `git` und jedes Werkzeug,
das über SSH einen Befehl absetzt, davon abhängt. Ein Umschalten auch dieses
Pfades würde nicht einen PowerShell-Prompt erzeugen, sondern jede
Dateiübertragung zur Maschine zerstören.

## 2.2 Welche Maschine ist das?

Die erste Frage auf einer unbekannten Maschine:

```powershell
Get-OS7Version
```

![Get-OS7Version nennt die Version, die Ausgabe ist ein Objekt und keine Textzeile.](images/10-get-os7version.png)

Mit `-Detailed` kommt alles dazu, was die Maschine über sich selbst weiß —
der Commit, aus dem sie gebaut wurde, der Archiv-Snapshot, gegen den sie
gebaut wurde, und die Bootumgebung, aus der sie gerade läuft:

```powershell
Get-OS7Version | Format-List *
```

![Alle Felder der Version. Sie stammen aus /usr/lib/os7/release.json, derselben Datei, die auch Setup und der Bootmenü-Eintrag lesen.](images/11-get-os7version-list.png)

### Zwei Schreibweisen einer Version

OS/7 zeigt einer **Person** drei Felder und einer **Maschine** vier:

| | Beispiel | Wo es steht |
|---|---|---|
| kurz | `1.0.0 (development)` | Titelzeile, `PRETTY_NAME`, `/etc/issue`, Begrüßung, `Get-OS7Version` |
| lang | `1.0.0.148` | Dataset-Namen, `IMAGE_VERSION`, ISO-Dateiname, `--version`, Bootmenü, Abschlussbildschirm von Setup |

Das ist **eine Anzeigeregel, keine zweite Nummer**. Überall, wo zwei Bauten
auseinandergehalten werden müssen, steht die lange Form; überall, wo ein
Mensch liest, die kurze.

### Was die Maschine wem gegenüber heißt

Eine OS/7-Maschine nennt sich **OS/7, wo ein Mensch hinschaut, und Ubuntu, wo
Software hinschaut.** Gebrandet sind `PRETTY_NAME`, `/etc/issue`, die
Begrüßung und das GRUB-Menü. Nicht gebrandet sind `NAME`, `ID`, `ID_LIKE`,
`VERSION`, `VERSION_ID`, `VERSION_CODENAME`, `/etc/lsb-release` und `uname`.

Der Grund ist praktisch: Microsofts Onboarding-Skript für Azure Arc liest
`NAME` und bricht ab, wenn dort nicht `buntu` vorkommt. Andere Werkzeuge lesen
andere Felder. Deshalb liest jede gebrandete Oberfläche eine eigene Datei
(`/usr/lib/os7/product`) und keines der `os-release`-Felder.

## 2.3 Die Befehle finden

Alle Verwaltungsbefehle liegen in sechs Modulen, die auf jeder OS/7-Maschine
vorhanden sind:

```powershell
Get-Module -ListAvailable OS7,Zfs,Net,Time,Systemd
```

![Die Module, wie die Maschine sie meldet, mit ihren Pfaden und Versionen.](images/12-modules.png)

Von hier aus arbeiten Sie mit den PowerShell-Bordmitteln weiter. Alle Befehle
zu einem Thema:

```powershell
Get-Command -Module OS7 -Noun OS7BootEnvironment
```

![Alle Befehle rund um Bootumgebungen — gefunden über das Substantiv.](images/13-be-commands.png)

Mit Platzhaltern lässt sich das Thema weiter fassen:

```powershell
Get-Command -Module OS7 -Verb Get -Noun OS7B*
```

![Die Get-Befehle, deren Substantiv mit OS7B beginnt: Bootumgebungen und Sicherung.](images/14-verbs.png)

Und weiter:

```powershell
Get-Command -Module OS7 -Noun *Backup*     # alles zum Thema Sicherung
Get-Command -Module OS7 -Verb Set          # alles, was etwas verändert
Get-Help Update-OS7 -Full                  # die vollständige Hilfe
Get-Help Restore-OS7 -Examples             # nur die Beispiele
```

Die vollständige Liste aller 185 Befehle steht in **Anhang A**.

## 2.4 Die Namensregeln

Wer die Regeln kennt, muss weniger nachschlagen.

**Ein `Get-` ändert nie etwas.** Ohne Ausnahme.

**Ein `Test-` beantwortet eine Frage und sagt bei „nein" auch, woran es lag.**
`Test-OS7Network` meldet nicht nur, dass ein Endpunkt nicht erreichbar ist,
sondern welcher und in welchem Schritt es hakte.

**Ein `Set-` prüft nach.** `Set-OS7NetworkAdapter` schreibt die Konfiguration,
wendet sie an, fragt den Kernel, ob tatsächlich eine Adresse anliegt — und
**nimmt die alte Konfiguration zurück**, wenn nicht.

**Zerstörende Befehle fragen nach.** `Remove-OS7BootEnvironment`,
`Remove-ZfsDataset`, `Remove-Zpool` und `Restore-ZfsSnapshot` sind als
hochriskant eingestuft und verlangen eine Bestätigung. In Skripten unterdrückt
man sie mit `-Confirm:$false`, und dann ist es eine bewusste Entscheidung.

**Kennwörter sind nie Zeichenketten.** Jedes Cmdlet, das ein Geheimnis
entgegennimmt, nimmt ein `[securestring]` oder ein `[pscredential]`. Es gibt
keinen Parameter, der ein Kennwort im Klartext annimmt, und keines dieser
Objekte landet in einer Ausgabe, die sich serialisieren lässt.

## 2.5 Womit man anfängt

Auf einer fremden Maschine geben diese fünf Befehle in etwa einer Minute ein
vollständiges Bild:

```powershell
Get-OS7Version                  # welches OS/7 ist das
Get-OS7BootEnvironment          # was kann sie starten, was läuft gerade
Get-OS7Service -Detailed | ? { $_.Healthy -eq $false }  # was ist nicht gesund
Test-OS7Network                 # kommt sie raus, und wohin
Get-OS7ManagementStatus         # ist sie verwaltet, und wenn nein, warum nicht
```

Kapitel 14 baut daraus eine vollständige Reihenfolge für die Fehlersuche.
