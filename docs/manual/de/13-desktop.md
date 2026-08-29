# 13 Der Desktop

Der Desktop gehört zur **amd64**-Ausgabe von OS/7; auf arm64 gibt es ihn
nicht, weil Microsoft dort keinen Desktop-Stapel liefert. Er wird bei der
Installation gewählt (Bildschirm 8, „GUI").

## 13.1 Was darauf liegt

![Der OS/7-Desktop im klassischen Erscheinungsbild.](images/desktop-01b-desktop-no-overview.png)

Technisch ist es GNOME. Erscheinungsbild und Bedienung sind auf das klassische
Windows-Muster gebracht: eine Leiste unten, ein Startmenü links, ein
Infobereich rechts, quadratische Fenster mit sichtbaren Rahmen.

![Der Dateimanager.](images/desktop-03-desktop-files.png)

Mitgeliefert sind **Microsoft Edge** als Standardbrowser und das
**Intune-Unternehmensportal**:

![Microsoft Edge.](images/desktop-04-desktop-edge.png)

![Das Intune-Unternehmensportal.](images/desktop-05-desktop-intune.png)

## 13.2 Das Terminalfenster

Ein Terminalfenster auf dem Desktop landet in **PowerShell**, genau wie die
Konsole und wie ein interaktiver SSH-Login:

![Ein Terminalfenster auf dem Desktop: PowerShell, wie überall sonst.](images/desktop-02b-desktop-terminal-version.png)

Das ist ausdrücklich eingerichtet und nicht selbstverständlich. Ein
Terminalemulator startet die Shell normalerweise **nicht** als Anmeldeshell,
und die Datei, in der die Übergabe an PowerShell steht, wird nur von
Anmeldeshells gelesen. Auf OS/7 ist das Standardprofil des Terminals deshalb
auf „als Anmeldeshell starten" gesetzt — so läuft dieselbe Übergabe wie
überall.

## 13.3 Das Erscheinungsbild umschalten

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

## 13.4 Anmeldebildschirm und Konsole

Der Anmeldebildschirm ist ebenfalls gebrandet. Er liest seine Einstellungen
aus einer **anderen** Datenbank als die angemeldete Sitzung — wer dort etwas
ändert, ändert es an zwei Stellen oder an keiner.

Die Textkonsole benutzt eine andere Schrift als der Installer: der Installer
zeigt Fixedsys, die installierte Konsole **Cascadia Mono**. Das ist Absicht —
Setup soll aussehen wie ein Installer aus der Zeit, die installierte Maschine
wie ein Arbeitsgerät von heute.

## 13.5 Was auf dem Desktop nicht anders ist

Alles aus diesem Handbuch. Es gibt keine grafische Verwaltungsoberfläche, die
neben den Cmdlets ein zweites Regelwerk aufmachen würde: Bootumgebungen,
Updates, Netzwerk, Sicherung und Verzeichnis werden auf einer Desktop-Maschine
mit denselben Befehlen bedient wie auf einem Server.
