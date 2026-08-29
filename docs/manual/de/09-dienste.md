# 9 Dienste, Protokolle und Fernzugriff

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
Set-OS7Service -Name os7-update-check.timer -StartupType Automatic
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

## 9.5 Was nicht nachgebaut wurde

OS/7 baut nichts nach, was PowerShell auf Linux schon kann. Es gibt kein
`Get-OS7Process`, kein `Get-OS7FileHash`, kein `Restart-OS7Computer` und kein
`Test-OS7Connection` — `Get-Process`, `Get-FileHash`, `Restart-Computer` und
`Test-Connection` funktionieren hier ganz normal.

Der Aufnahmetest lautet nicht „wäre das bequem", sondern „müsste ein
Administrator sonst einen Linux-Befehl eintippen".
