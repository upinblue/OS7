# 9 Dienste, geplante Aufgaben, Protokolle und Fernzugriff

## 9.1 Dienste

Was auf einer Linux-Maschine ein *Dienst* ist, verwaltet **systemd** als
*Unit*. `Get-OS7Service` stellt sie als Objekte bereit — und beantwortet dabei
eine Frage, die `systemctl` nicht beantwortet.

```powershell
Get-OS7Service -OS7Only -Detailed
```

![Die Dienste, die zu OS/7 gehören, mit dem Gesundheitsurteil.](images/50-services.png)

### `Healthy` ist nicht `active`

Und zwar in **beide** Richtungen. Das ist der Grund, warum es diese Spalte
gibt:

**`Healthy = $false`, obwohl `systemctl` `active` sagt.** Ein Dienst in einer
Neustartschleife hat den Unterzustand `auto-restart`, und `systemctl
is-active` meldet dafür `active`. Er ist nicht gesund.

**`Healthy = $true`, obwohl der Dienst nicht läuft.** Eine Unit vom Typ
`oneshot` — etwa `zfs-mount.service` — ist nach erfolgreichem Durchlauf
`inactive/dead`, und das ist ihr korrekter Endzustand. Eine Prüfung, die
„läuft nicht" als „krank" liest, meldet auf einer völlig gesunden Maschine
einen Fehler. Genau das tat die erste Fassung dieses Feldes.

`Healthy` ist deshalb `$false`, wenn eines davon zutrifft:

* die Unit ist `failed`;
* sie ist in einer Neustartschleife;
* sie wurde aus einem anderen Grund als Erfolg beendet;
* sie ist für den Systemstart aktiviert, ist ein Dienst, der **oben bleiben
  soll**, und läuft nicht.

> **`-Detailed` ist Pflicht, wenn Sie `Healthy` auswerten wollen.** Ohne
> diesen Schalter wurden die Details nicht abgerufen, und `Healthy` ist
> `$null` — nicht `$false`. Ein `Where-Object { -not $_.Healthy }` ohne
> `-Detailed` liefert daher **alle** Dienste.
>
> Richtig ist:
> ```powershell
> Get-OS7Service -Detailed | Where-Object { $_.Healthy -eq $false }
> ```

Ein einzelner Dienst:

```powershell
Get-OS7Service -Name ssh.service -Detailed | Format-List
```

![Ein Dienst im Detail.](images/51-one-service.png)

### Dienste steuern

```powershell
Start-OS7Service   -Name chrony.service
Stop-OS7Service    -Name chrony.service
Restart-OS7Service -Name chrony.service
```

Jeder dieser Befehle meldet, **was die Unit geworden ist** — nicht, was von ihr
verlangt wurde. Ein `Start-`, das mit einem Objekt zurückkommt, dessen
`ActiveState` nicht `active` ist, ist ein fehlgeschlagener Start und sieht auch
so aus.

Ob ein Dienst beim Systemstart hochkommt:

```powershell
Set-OS7Service -Name ssh.service -StartupType Automatic
```

Zur Wahl stehen `Automatic`, `Manual`, `Disabled` und `Blocked`. `Blocked`
ist stärker als `Disabled`: es verhindert auch, dass ein anderer Dienst die
Unit als Abhängigkeit mitzieht.

## 9.2 Protokolle

```powershell
Get-OS7Log -Tail 6 | Format-Table Timestamp,Unit,Message
```

Weil das Objekte sind, filtert man mit PowerShell und nicht mit `grep`:

```powershell
Get-OS7Log -Priority Error -Since (Get-Date).AddHours(-2)
Get-OS7Log -Unit ssh.service -Tail 50
Get-OS7Log -OS7Only -Boot 0
Get-OS7Log -Since '2026-08-28 14:00' -Until '2026-08-28 15:00' |
    Group-Object Unit | Sort-Object Count -Descending
```

`-Boot 0` ist der laufende Start, `-Boot -1` der vorhergehende — nützlich nach
einem unerwarteten Neustart.

Gefiltert wird nach dem Feld `Unit`, das systemd selbst setzt, nicht nach dem,
was der Absender behauptet. Andernfalls könnte ein Programm steuern, ob es in
einem gefilterten Protokoll auftaucht.

## 9.3 Das Installationsprotokoll

Die Installation selbst hat kein Journal — das System, das sie protokolliert
hätte, gab es zu diesem Zeitpunkt noch nicht. Setup schreibt daher eine eigene
Datei auf die Maschine, mit dem Selbstnachweis jedes Schrittes:

```powershell
Get-OS7InstallLog | Select -Skip 4 -First 8 Message
```

![Das Protokoll der Installation, wie es auf der Maschine liegt.](images/53-install-log.png)

Die Datei liegt unter `/var/log/os7-setup/install.log` mit den Rechten `0600`
und liegt **in** der Bootumgebung — sie überlebt also einen Rollback, weil sie
zu genau dieser Installation gehört.

Geheimnisse stehen nicht darin. Wo eines eine Rolle spielte, steht
`[not kept]` — die Zeile bezeugt, dass etwas übergeben wurde, ohne zu sagen,
was.

## 9.4 Fernzugriff mit PowerShell

```powershell
Get-OS7Remoting | Format-List
```

![Ob diese Maschine per PowerShell erreichbar ist — und zwar in beiden Bedeutungen der Frage.](images/80-remoting.png)

„Erreichbar per PowerShell" kann zweierlei heißen, und der Befehl beantwortet
beides getrennt:

* **Ein interaktiver SSH-Login landet in PowerShell.** Das ist auf jeder
  OS/7-Maschine so und braucht nichts.
* **`Enter-PSSession -HostName` funktioniert.** Das braucht ein
  Untersystem im SSH-Dienst, das nicht von vornherein eingerichtet ist.

Das Zweite einschalten:

```powershell
Enable-OS7Remoting
```

Danach von einem anderen Rechner aus:

```powershell
Enter-PSSession -HostName os7-srv-01 -UserName os7admin
Invoke-Command -HostName os7-srv-01 -UserName os7admin -ScriptBlock {
    Get-OS7BootEnvironment
}
```

Wieder abschalten:

```powershell
Disable-OS7Remoting
```

> **WinRM gibt es nicht.** `New-PSSession -ComputerName` existiert als
> Parameter und antwortet mit „no supported WSMan client library was found".
> Der Weg auf eine OS/7-Maschine ist SSH-basiertes Remoting, also
> `-HostName`. Das ist PowerShells eigener Mechanismus und funktioniert auch
> von Windows aus.

## 9.5 Geplante Aufgaben

Was unter Windows die Aufgabenplanung ist, sind hier **systemd-Timer** — und
die sind mit Absicht keine Dienste. `Get-OS7Service` beantwortet „läuft dieses
Programm"; `Get-OS7ScheduledTask` beantwortet „was wird laufen, und wann":

```powershell
Get-OS7ScheduledTask | Format-Table Name,NextRun,LastRun
```

![Alles, was nach Zeitplan läuft, mit dem nächsten und dem letzten Lauf.](images/54-scheduled-tasks.png)

Die Liste enthält auch Aufgaben, die gerade abgeschaltet sind — eine Aufgabe,
die Sie deaktiviert haben, hat nicht aufgehört zu existieren, und ein
Inventar, das sie verliert, wäre ein Inventar, dem man nicht trauen kann.

Drei dieser Zeitpläne gehören dem Produkt selbst: `sanoid.timer` nimmt die
Sicherungs-Snapshots (Kapitel 12), `os7-backup-replicate.timer` kopiert sie
auf das Sicherungsziel, und `os7-update-check.timer` ist die unbeaufsichtigte
Update-Prüfung (Kapitel 6.7). Sie werden verwaltet wie jede andere Aufgabe —
gehören aber dem Produkt, und das zählt bei `Unregister-` weiter unten.

Eine Aufgabe im Ganzen:

```powershell
Get-OS7ScheduledTask sanoid.timer | Format-List
```

![Eine geplante Aufgabe im Detail — Zeitplan, nächster Lauf, letzter Lauf und dessen Ausgang.](images/55-task-detail.png)

`LastRun` ist, wann der **Zeitplan** zuletzt ausgelöst hat; `LastResult` ist,
wie dieser Lauf ausging. Startet man eine Aufgabe von Hand, bewegt sich
`LastResult` und nicht `LastRun` — der Zeitplan hat nicht ausgelöst, und die
beiden Antworten bleiben mit Absicht getrennt.

### `Healthy`, und die Falle, die es benennt

Ein Timer kann **aktiviert sein und trotzdem nie laufen**: systemds `enable`
schärft den *nächsten Systemstart* und sonst nichts. Ein Timer in diesem
Zustand ist aktiviert, inaktiv, und feuert bis zum Neustart der Maschine nicht
— und kein Werkzeug auf der Maschine nennt das ein Problem.
`Get-OS7ScheduledTask` tut es: `Healthy` ist `$false`, und `NextRun` ist leer.

`Enable-OS7ScheduledTask` macht deshalb beides — es aktiviert die Aufgabe
*und* schärft sie sofort:

```powershell
Enable-OS7ScheduledTask  os7-update-check.timer
Disable-OS7ScheduledTask os7-update-check.timer
```

`Healthy` ist außerdem `$false` für eine Aufgabe, deren letzter Lauf
fehlschlug. Wie überall sonst ist es `$null`, wenn die Details nicht abgerufen
wurden — eine Prüfung, die nicht lief, darf nie wie eine bestandene aussehen.

### Eine Aufgabe sofort ausführen

```powershell
Start-OS7ScheduledTask os7-update-check.timer
```

Das startet den **Dienst** der Aufgabe, wartet auf ihn und meldet, was
geschehen ist — derselbe Lauf, den der Zeitplan erzeugt hätte, nur jetzt.

### Eine eigene Aufgabe anlegen

Ein wöchentlicher Pool-Scrub, sonntags um drei Uhr morgens — die Parameter
passen nicht mehr auf eine Zeile, also werden sie gesplattet; das ist das
Idiom für jeden Parametersatz, der einer Zeile entwachsen ist:

```powershell
$t = @{ Name='scrub'; Weekly=$true; DayOfWeek='Sunday' }
```

![Die Parameter der Aufgabe, in einer Hashtable gesammelt.](images/56-register-a.png)

```powershell
$t += @{ At='03:00'; Command='Start-ZpoolScrub rpool' }
```

![Zeitplan und Befehl kommen dazu.](images/57-register-b.png)

```powershell
Register-OS7ScheduledTask @t
```

![Die registrierte Aufgabe, scharf — NextRun hat einen Wert.](images/58-register.png)

Die Aufgabe heißt `os7-task-scrub` — jede Aufgabe, die Sie registrieren, trägt
das Präfix `os7-task-`, und daran ist sie in jeder Auflistung als Ihre zu
erkennen. `-Command` führt PowerShell aus; für alles andere gibt es
`-Execute`/`-Arguments` mit einem absoluten Pfad. `-Daily -At` und
`-Weekly -DayOfWeek -At` decken die üblichen Zeitpläne ab; `-OnCalendar` nimmt
einen rohen systemd-Kalenderausdruck für alles, was sie nicht sagen können
(`'Mon..Fri 06:30'`, `'*-*-01 06:00:00'`). Der Zeitplan wird geprüft,
**bevor** etwas geschrieben wird — einen Ausdruck, den systemd nicht parsen
kann, lehnt der Befehl mit systemds eigener Fehlermeldung ab, statt ihn als
Timer auf die Platte zu schreiben, der nie feuert.

Zwei Schalter lohnen sich zu kennen: `-Persistent` holt Versäumtes nach (eine
Maschine, die um drei aus war, führt den Auftrag beim Wiederanlauf aus), und
`-RandomizedDelay` verteilt die Läufe einer Flotte über ein Zeitfenster, damit
nicht tausend Maschinen denselben Auftrag in derselben Sekunde beginnen.

> **Keine Geheimnisse in `-Command`.** Die Befehlszeile landet in einer für
> alle lesbaren Unit-Datei und erscheint in systemds eigenen Werkzeugen. Eine
> Aufgabe, die eine Anmeldung braucht, liest sie zur Laufzeit aus einer Datei,
> die root gehört und die Rechte `0600` hat.

### Eine Aufgabe entfernen

```powershell
Unregister-OS7ScheduledTask scrub -Confirm:$false
```

![Die Aufgabe wird angehalten, entschärft und entfernt.](images/59-unregister.png)

`Unregister-` entfernt **nur** Aufgaben, die mit `Register-` angelegt wurden —
`sanoid.timer` und die anderen Produkt-Zeitpläne lehnt es beim Namen ab. Die
gehören Paketen, und die Unit-Datei eines Pakets zu löschen hieße, die
Paketverwaltung an eine Datei glauben zu lassen, die nicht mehr da ist. Einen
Produkt-Zeitplan, den man stilllegen will, schaltet man ab, statt ihn zu
entfernen:

```powershell
Disable-OS7ScheduledTask sanoid.timer
```

## 9.6 Was nicht nachgebaut wurde

OS/7 baut nichts nach, was PowerShell auf Linux schon kann. Es gibt kein
`Get-OS7Process`, kein `Get-OS7FileHash`, kein `Restart-OS7Computer` und kein
`Test-OS7Connection` — `Get-Process`, `Get-FileHash`, `Restart-Computer` und
`Test-Connection` funktionieren hier ganz normal.

Der Aufnahmetest lautet nicht „wäre das bequem", sondern „müsste ein
Administrator sonst einen Linux-Befehl eintippen".
