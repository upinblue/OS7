# 13 Der Desktop

Der Desktop gehört zur **amd64**-Ausgabe von OS/7; auf arm64 gibt es ihn
nicht, weil Microsoft dort keinen Desktop-Stapel liefert. Er wird bei der
Installation gewählt (Bildschirm 8, „Desktop").

## 13.1 Was darauf liegt

![Der Desktop mit geöffnetem Startmenü: das klassische Erscheinungsbild und was installiert ist.](images/desktop-01-desktop.png)

Technisch ist es GNOME. Erscheinungsbild und Bedienung sind auf das klassische
Windows-Muster gebracht: eine Leiste unten, ein Startmenü links, ein
Infobereich rechts, quadratische Fenster mit sichtbaren Rahmen.

![Der Dateimanager.](images/desktop-03-files.png)

Mitgeliefert sind **Microsoft Edge** als Standardbrowser und das
**Intune-Unternehmensportal**:

![Microsoft Edge auf einer Maschine, auf der er noch nicht gestartet wurde.](images/desktop-04-edge.png)

![Das Intune-Unternehmensportal.](images/desktop-05-intune.png)

## 13.2 Die zwei OS/7-Anwendungen

Zwei Anwendungen auf dem Desktop sind OS/7s eigene. Beide sind Oberflächen über
Cmdlets, die dieses Handbuch schon beschreibt, und keine bringt eine eigene
Regel mit:

| Anwendung | Wo sie liegt | Wofür | Beschrieben in |
|---|---|---|---|
| **Software Update** | Apps → System Tools | ein neues Release installieren | 6.5 |
| **Versions** | Rechtsklick auf eine Datei in Dateien → *Versions* | Vorgängerversionen einer Datei ansehen und zurückholen | 12.8 |

![Software Update: die Releases, die der Kanal anbietet.](images/app-software-update.png)

![Versions: die Historie einer Datei.](images/app-versions.png)

Software Update hat einen Eintrag im Startmenü, Versions absichtlich nicht:
Versions ist eine Frage nach *einer Datei* und bekommt einen Pfad, der Weg
hinein ist also der Dateimanager. Beide sind englisch, wie die ganze
Anwendungsfamilie in diesem Release.

Ihre Fenster zeichnet dasselbe Designsystem — quadratische Rahmen mit Fase, die
Windows-2000-Palette, eine Titelzeile, die Mutter aus dem Desktop-Thema zeichnet
— und die Palette ist eine Tabelle, die sie mit dem CSS des Desktops teilen, und
nicht ein zweiter Satz Farben, der auseinanderlaufen könnte.

Keine der beiden hat Administratorrechte. Software Update fragt polkit und lässt
systemd `Update-OS7` als root ausführen; Versions läuft vollständig als die
Person, die es benutzt — und deshalb bewahrt ein Zurückholen die ersetzte Datei
durch Umbenennen und nicht durch einen Snapshot (12.8).

## 13.3 Das Terminalfenster

Ein Terminalfenster auf dem Desktop landet in **PowerShell**, genau wie die
Konsole und wie ein interaktiver SSH-Login:

![Ein Terminalfenster auf dem Desktop: PowerShell, wie überall sonst.](images/desktop-02-terminal.png)

Das ist ausdrücklich eingerichtet und nicht selbstverständlich. Ein
Terminalemulator startet die Shell normalerweise **nicht** als Anmeldeshell,
und die Datei, in der die Übergabe an PowerShell steht, wird nur von
Anmeldeshells gelesen. Auf OS/7 ist das Standardprofil des Terminals deshalb
auf „als Anmeldeshell starten" gesetzt — so läuft dieselbe Übergabe wie
überall.

## 13.4 Das Erscheinungsbild umschalten

```powershell
Get-OS7Theme
Set-OS7Theme -Name Classic     # das klassische OS/7-Erscheinungsbild
Set-OS7Theme -Name Stock       # unverändertes GNOME
```

Die Umschaltung gilt für die **aktuelle Sitzung** und wirkt nach dem nächsten
Anmelden vollständig.

`Stock` ist nicht nur zur Zierde da: Wenn ein Problem am Desktop auftritt,
trennt ein Umschalten auf `Stock` die Frage „liegt es am Erscheinungsbild" von
der Frage „liegt es an GNOME" — und das ist bei Darstellungsproblemen die
erste sinnvolle Halbierung.

## 13.5 Anmeldebildschirm und Konsole

Der Anmeldebildschirm ist ebenfalls gebrandet. Er liest seine Einstellungen
aus einer **anderen** Datenbank als die angemeldete Sitzung — wer dort etwas
ändert, ändert es an zwei Stellen oder an keiner.

Die Textkonsole benutzt eine andere Schrift als der Installer: der Installer
zeigt Fixedsys, die installierte Konsole **Cascadia Mono**. Das ist Absicht —
Setup soll aussehen wie ein Installer aus der Zeit, die installierte Maschine
wie ein Arbeitsgerät von heute.

## 13.6 Was auf dem Desktop nicht anders ist

Alles aus diesem Handbuch. Die zwei Anwendungen aus 13.2 sind Fenster auf
Cmdlets und kein zweites Regelwerk: ein Update aus Software Update ist dasselbe
`Update-OS7`, und eine aus Versions zurückgeholte Fassung ist dasselbe
`Restore-OS7File`, mit derselben Sicherungsregel und denselben Verweigerungen.
Alles andere — Bootumgebungen, Netzwerk, Sicherung, Verzeichnis — hat überhaupt
kein Fenster und wird auf einer Desktop-Maschine mit denselben Befehlen bedient
wie auf einem Server.
