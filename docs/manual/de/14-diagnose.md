# 14 Diagnose

Dieses Kapitel ist eine Reihenfolge, keine Befehlsliste. Die Befehle stehen in
den Kapiteln davor; hier steht, in welcher Folge man sie stellt und warum die
Folge so und nicht anders ist.

## 14.1 Die Grundregel

**Fragen Sie die Sache selbst, nicht ihren Rückgabewert.**

Die teuersten Fehler haben alle dieselbe Form: Ein Programm hat Erfolg
gemeldet, und die Sache, die es verändern sollte, wurde nicht verändert. Ein
Rückgabewert ist ein Hinweis. Eine Protokollzeile auch.

Praktisch heißt das: Wenn ein Befehl sagt, er habe die Netzwerkkonfiguration
geschrieben, fragen Sie den Kernel, welche Adresse auf dem Adapter liegt. Wenn
ein Dienst `active` meldet, fragen Sie nach `Healthy`. Die Cmdlets in diesem
Handbuch tun das von sich aus — der Grundsatz gilt für alles, was Sie
daneben tun.

**Und: ein Diagnosewerkzeug darf nicht von dem abhängen, was es diagnostiziert.**
Der Zustand des Netzwerks lässt sich nicht über das Netzwerk erfragen; der
Zustand von systemd nicht über einen Dienst, den systemd startet.

## 14.2 Erstaufnahme einer Maschine

```powershell
Get-OS7Version                                  # welches OS/7, welche Bootumgebung
Get-OS7BootEnvironment | Format-Table Name, Active, Running, Menu, Release
Get-Zpool | Format-Table Name, Health, Free
Get-OS7Service -Detailed | Where-Object { $_.Healthy -eq $false }
Test-OS7Network
Get-OS7ManagementStatus
```

Sechs Befehle, etwa eine Minute. Wenn hier alles unauffällig ist, liegt das
Problem nicht an der Grundausstattung der Maschine.

## 14.3 Anmeldung schlägt fehl

Der häufigste Irrweg: Das Kennwort wird für falsch gehalten, weil die
Fehlermeldung das sagt.

```powershell
# 1. Die Uhr. Kerberos verweigert bei mehr als fünf Minuten Abweichung,
#    und die Meldung lautet dann "falsches Kennwort".
Get-OS7TimeSynchronization
Get-OS7Time

# 2. Bei Entra: fehlt der Vermittler? Auch das sieht aus wie ein falsches Kennwort.
Get-OS7EntraStatus

# 3. Bei einer Domäne: welches Glied der Kette fehlt?
Test-OS7Directory -Domain contoso.local
Test-OS7Domain   -Domain contoso.local

# 4. Erst jetzt das Protokoll.
Get-OS7Log -Priority Error -Since (Get-Date).AddMinutes(-15)
```

Die Reihenfolge ist so gewählt, dass die Ursachen, die sich als etwas anderes
tarnen, zuerst geprüft werden.

## 14.4 Kein Netz

```powershell
Get-OS7NetworkAdapter                 # gibt es einen Adapter, hat er Verbindung?
Get-OS7NetworkConfiguration           # konfiguriert und tatsächlich — stimmen sie überein?
Test-OS7Network                       # an welchem Glied reißt die Kette?
```

Der zweite Befehl ist der aufschlussreiche. Ein häufiger Fall ist eine
netplan-Datei, die einen Adapter beschreibt, den es auf dieser Maschine nicht
gibt — netplan nimmt das wortlos hin und konfiguriert nichts.

Nach einer misslungenen Umstellung:

```powershell
Set-OS7NetworkAdapter -Name enp0s31f6 -Dhcp
```

Und wenn ein früherer Versuch mit `RollbackFailed` endete, ist die Maschine an
der Konsole zu behandeln — dort war die Rücknahme selbst gescheitert.

## 14.5 Die Maschine startet nicht mehr

1. Im Bootmenü den Eintrag der **vorherigen Bootumgebung** wählen. Es gibt für
   jede vollständige Umgebung einen.
2. Ist die Maschine oben, das Umschalten dauerhaft machen:
   ```powershell
   Restore-OS7
   ```
3. Danach nachsehen, was in der neuen Umgebung nicht stimmte:
   ```powershell
   Get-OS7Log -Boot -1 -Priority Error
   ```

Kommt die Maschine in eine initramfs-Eingabezeile, ist der Datenträger nicht
freigeschaltet oder der Pool nicht importiert worden. Das ist die Ecke, in der
die Passphrase gebraucht wird — die TPM-Freischaltung greift nicht, wenn sich
die Startkette verändert hat, etwa nach einem Firmware-Update.

## 14.6 Ein Update ging schief

```powershell
Get-OS7BootEnvironment | Format-Table Name, Active, Running, Menu, Complete, Release
```

Lesen Sie `Running`, nicht `Active` — während eines Updates sind zwei
Umgebungen `Active` und nur eine läuft.

`Complete = False` bedeutet, dass einer Umgebung eine Hälfte fehlt. Eine solche
Umgebung sollte man nicht starten; sie wird entfernt und das Update neu
angestoßen.

Zurück:

```powershell
Restore-OS7
```

## 14.7 Der Pool ist voll

```powershell
Get-ZfsSpace rpool | Format-List
Get-ZfsDataset | Sort-Object Used -Descending | Select-Object -First 10 Name, Used
Get-ZfsSnapshot | Sort-Object Used -Descending | Select-Object -First 10 Name, Used
Get-OS7BootEnvironment | Format-Table Name, Used, Running
```

Drei übliche Ursachen, in dieser Häufigkeit:

1. **Alte Bootumgebungen.** Jede hält die Unterschiede zu ihrem Ursprung fest.
   `Remove-OS7BootEnvironment` räumt auf, und `Update-OS7 -Keep` verhindert
   die Ansammlung.
2. **Snapshots der Sicherungsrichtlinie.** Die Aufbewahrung ist mit
   `Set-OS7BackupPolicy -Retention` einstellbar.
3. **Von Hand angelegte Snapshots**, die niemand mehr entfernt hat.

## 14.8 Was gemeldet werden sollte

Wenn Sie einen Fehler weitergeben, hängen Sie das an — es beantwortet die
meisten Rückfragen im Voraus:

```powershell
Get-OS7Version -Detailed
Get-OS7BootEnvironment | Format-Table *
Get-OS7Service -Detailed | Where-Object { $_.Healthy -eq $false } | Format-Table *
Get-OS7Log -Priority Error -Boot 0 | Select-Object -Last 50
Get-OS7InstallLog | Select-Object -Last 40
```

Das Installationsprotokoll ist besonders nützlich, weil es den Selbstnachweis
jedes Installationsschrittes enthält — und weil es einen Rollback überlebt.
