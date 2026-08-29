# 1 Einführung

## 1.1 Was OS/7 ist

OS/7 ist ein Linux-Betriebssystem auf der Grundlage von **Ubuntu 26.04 LTS**,
das für Administratoren gebaut ist, die aus der Microsoft-Welt kommen. Es
ändert nicht, was Linux ist — es ändert, womit man es bedient und wie man es
verwaltet.

Vier Entscheidungen prägen alles Weitere:

**PowerShell ist die Bedienoberfläche.** Wer sich anmeldet, landet in
PowerShell, nicht in `bash`. Die Verwaltungsbefehle sind Cmdlets mit den
gewohnten Verb-Substantiv-Namen und geben **Objekte** zurück, keine
Textzeilen — `Get-OS7Service -Detailed | ? { $_.Healthy -eq $false }` ist eine
sinnvolle Zeile und braucht kein `grep`, kein `awk` und keine Annahme über
Spaltenbreiten.

**Die Verwaltung läuft über Microsofts Werkzeuge.** Entra ID für die Anmeldung,
Intune für die Geräteverwaltung, Azure Arc für die Inventarisierung. Wo eine
technische Vorliebe von OS/7 mit einer Anforderung dieser Dienste kollidiert,
gewinnt der Dienst — das gilt insbesondere für die Datenträgeraufteilung, die
Verschlüsselung und die Kennungen, unter denen sich die Maschine meldet.

**Das Dateisystem ist ZFS, und Updates sind zurückrollbar.** Ein Update
verändert nie das laufende System. Es legt eine Kopie an, verändert die Kopie
und schaltet danach um. Geht etwas schief, ist der Weg zurück ein Befehl und
ein Neustart — nicht eine Wiederherstellung aus einer Sicherung.

**Setup ist ein Textmodus-Installer im Stil von MS-DOS 6.22 und der Textphase
von Windows 2000.** Das ist keine Nostalgie: ein Installer, der auf jeder
seriellen Konsole und in jedem Fernwartungsfenster funktioniert, ist auf einem
Server mehr wert als einer, der einen Grafikstapel voraussetzt.

## 1.2 Für wen dieses Handbuch ist

Für Administratoren, die OS/7-Maschinen betreiben. Es setzt voraus, dass Sie
mit Windows Server und PowerShell vertraut sind. Linux-Kenntnisse sind
hilfreich, aber an keiner Stelle Voraussetzung: wo ein Linux-Konzept
unvermeidlich ist — ZFS, systemd, netplan — erklärt das Handbuch es an der
Stelle, an der es gebraucht wird.

Das Handbuch ist **nach Tätigkeiten gegliedert**, nicht nach Modulen. Wer
wissen will, wie ein Update zurückgerollt wird, findet das in Kapitel 5, mit
allem, was dazugehört. Die vollständige Liste aller Befehle steht in
**Anhang A**.

## 1.3 Die beiden Architekturen

OS/7 gibt es für zwei Prozessorarchitekturen, und sie sind **nicht dasselbe
Produkt**:

| | **amd64** (x86-64) | **arm64** (AArch64) |
|---|---|---|
| Desktop | ja — GNOME im klassischen Erscheinungsbild | nein |
| Microsoft Edge | ja | nein |
| Intune-Portal | ja | nein |
| Server / Headless | ja | ja |
| PowerShell, ZFS, Bootumgebungen, Updates, Netzwerk, Zeit, Verzeichnis | ja | ja |

Der Grund für den Schnitt ist einfach: Microsoft liefert keinen
Desktop-Stapel für arm64. Alles, was OS/7 selbst baut, gibt es auf beiden
Architekturen; alles, was von Microsoft kommt, nur dort, wo Microsoft es
liefert. Beim Installieren wählt man auf amd64 zwischen **GUI** und
**Headless**; auf arm64 entfällt die Frage.

## 1.4 Wie das System aufgebaut ist

Die Befehle, die Sie in diesem Handbuch benutzen, kommen aus sechs
PowerShell-Modulen. Die Aufteilung ist keine Kosmetik, sondern der Grund,
warum die Befehle sich gleichartig verhalten:

![Die sechs Module und ihre Richtung. Die fünf generischen Module kennen jeweils ein Subsystem des Betriebssystems und wissen nichts von OS/7; das Modul OS7 ist das Produkt darüber und enthält jede Entscheidung, die OS/7-spezifisch ist.](images/diagram-layers-de.svg)

Was das praktisch bedeutet:

* **`Get-Zpool` funktioniert auf jedem Ubuntu.** Die generischen Module sind
  Werkzeuge für ihr Subsystem und sonst nichts. Sie kennen keine
  Bootumgebungen, keine Releases und keine Richtlinien.
* **`Get-OS7BootEnvironment` gibt es nur hier.** Alles mit `OS7` im Namen ist
  Produktwissen und stützt sich auf die Schicht darunter.
* **Der Präfix `OS7` ist verbindlich.** Es gibt kein `Get-Service`, sondern
  `Get-OS7Service`. Das ist Absicht: die Parameter dieser Cmdlets stimmen nicht
  mit denen der gleichnamigen Windows-Cmdlets überein, und ein Befehl, der
  denselben Namen trägt und ein Drittel der Parameter versteht, macht aus einem
  kopierten Skript ein halb funktionierendes — was schlimmer ist als eines, das
  in der ersten Zeile abbricht.

## 1.5 Zwei Antworten statt einer

Ein Muster zieht sich durch die ganze Befehlsoberfläche und ist beim ersten
Lesen ungewohnt: **wo es eine hinterlegte Absicht und eine laufende Wirklichkeit
gibt, meldet OS/7 beide getrennt.**

`Get-OS7NetworkConfiguration` sagt Ihnen, was in `netplan` steht **und** was
tatsächlich auf den Adaptern liegt. `Get-OS7Service` sagt, was systemd über die
Unit denkt **und** ob der Dienst wirklich gesund ist. Die interessante Maschine
ist genau die, bei der beides auseinanderfällt — ein zusammengefasstes Feld
würde diese Maschine verstecken.

Aus demselben Grund fragt jedes Cmdlet die Sache selbst und verlässt sich nicht
auf Rückmeldungen von Werkzeugen: `netplan apply` liefert 0 für eine
Konfiguration, die nichts hochgebracht hat; `systemctl is-active` sagt `active`
über einen Dienst in einer Neustartschleife; `useradd -m` beendet sich mit 0,
ohne das Home-Verzeichnis angelegt zu haben, wenn es schon existiert. Ein
Rückgabewert ist ein Hinweis, keine Antwort.

## 1.6 Konventionen in diesem Handbuch

Eingaben stehen in Codeblöcken, so wie sie einzutippen sind:

```powershell
Get-OS7BootEnvironment | Format-Table Name, Active, Running
```

Abbildungen von Bildschirmausgaben zeigen die Konsole einer laufenden
OS/7-Maschine.

> **Erhöhte Rechte.** Fast alle verändernden Cmdlets und viele lesende brauchen
> Administratorrechte, weil sie ZFS, systemd oder Dateien unter `/etc`
> anfassen. Auf OS/7 startet man dafür eine erhöhte PowerShell:
> ```powershell
> sudo pwsh
> ```
> Alle Beispiele in diesem Handbuch gehen davon aus, dass Sie in einer solchen
> Sitzung arbeiten, sofern nichts anderes dabeisteht.
