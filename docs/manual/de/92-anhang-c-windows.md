# Anhang C  Für Windows-Administratoren

Was Sie unter Windows tun, und womit es auf OS/7 geht. Die Tabelle ist eine
Landkarte, keine Gleichsetzung — wo sich die Begriffe unterscheiden, steht es
dabei.

## Das System und seine Version

| Windows | OS/7 |
|---|---|
| `winver`, `Get-ComputerInfo` | `Get-OS7Version`, `Get-OS7Version -Detailed` |
| `systeminfo` | `Get-OS7Version -Detailed`, `Get-OS7ManagementStatus` |
| Systemsteuerung → System | `Get-OS7Version`, `Get-OS7Home`, `Get-Zpool` |

## Dienste

| Windows | OS/7 |
|---|---|
| `Get-Service` | `Get-OS7Service` |
| `Get-Service \| Where Status -eq Running` | `Get-OS7Service -Detailed \| Where { $_.Healthy -eq $false }` |
| `Start-Service`, `Stop-Service`, `Restart-Service` | `Start-OS7Service`, `Stop-OS7Service`, `Restart-OS7Service` |
| `Set-Service -StartupType` | `Set-OS7Service -StartupType` |
| `services.msc` | `Get-OS7Service -OS7Only -Detailed` |

> Es heißt `Get-OS7Service` und nicht `Get-Service`, weil die Parameter nicht
> dieselben sind. Ein Cmdlet, das den Windows-Namen trägt und ein Drittel der
> Parameter versteht, macht aus einem kopierten Skript ein halb
> funktionierendes.

## Aufgabenplanung

| Windows | OS/7 |
|---|---|
| `Get-ScheduledTask`, `taskschd.msc` | `Get-OS7ScheduledTask` |
| `Get-ScheduledTaskInfo` | `Get-OS7ScheduledTask <name>` — `NextRun`, `LastRun`, `LastResult` |
| `Enable-ScheduledTask`, `Disable-ScheduledTask` | `Enable-OS7ScheduledTask`, `Disable-OS7ScheduledTask` |
| `Start-ScheduledTask` | `Start-OS7ScheduledTask` |
| `Register-ScheduledTask` | `Register-OS7ScheduledTask` |
| `Unregister-ScheduledTask` | `Unregister-OS7ScheduledTask` |
| `schtasks /create` | `Register-OS7ScheduledTask -Daily -At 03:00 -Command '…'` |

## Ereignisanzeige

| Windows | OS/7 |
|---|---|
| `Get-WinEvent`, `eventvwr` | `Get-OS7Log` |
| `Get-WinEvent -MaxEvents 50` | `Get-OS7Log -Tail 50` |
| Filter nach Quelle | `Get-OS7Log -Unit ssh.service` |
| Filter nach Stufe | `Get-OS7Log -Priority Error` |
| Ereignisse seit dem letzten Start | `Get-OS7Log -Boot 0`, davor `-Boot -1` |

## Netzwerk

| Windows | OS/7 |
|---|---|
| `Get-NetAdapter` | `Get-OS7NetworkAdapter` |
| `Get-NetIPConfiguration` | `Get-OS7NetworkConfiguration` |
| `New-NetIPAddress`, `Set-DnsClientServerAddress` | `Set-OS7NetworkAdapter -Address … -Nameserver …` |
| DHCP einschalten | `Set-OS7NetworkAdapter -Dhcp` |
| `Test-NetConnection` | `Test-OS7Network`, oder PowerShells eigenes `Test-Connection` |
| `ipconfig /all` | `Get-OS7NetworkAdapter \| Format-List` |

## Zeit

| Windows | OS/7 |
|---|---|
| `w32tm /query /status` | `Get-OS7TimeSynchronization` |
| `w32tm /resync` | `Sync-OS7Time` |
| `Set-TimeZone` | `Set-OS7TimeZone -Id Europe/Berlin` |
| `Get-Date` | `Get-Date` (unverändert), `Get-OS7Time` für die vollständige Antwort |

## Datenträger

| Windows | OS/7 |
|---|---|
| Datenträgerverwaltung, `Get-Disk`, `Get-Volume` | `Get-Zpool`, `Get-ZfsDataset` |
| `Get-Volume \| Select SizeRemaining` | `Get-ZfsSpace` |
| Eine Partition vergrößern | entfällt — Datasets teilen sich den freien Platz des Pools |
| `chkdsk` | `Start-ZpoolScrub` (prüft alle Daten gegen ihre Prüfsummen) |
| Volumeschattenkopien | ZFS-Snapshots: `New-ZfsSnapshot`, `Get-ZfsSnapshot` |
| Vorgängerversionen einer Datei | `Get-OS7FileVersion`, `Restore-OS7File` |

## Updates und Wiederherstellung

| Windows | OS/7 |
|---|---|
| Windows Update | `Get-OS7Release`, `Update-OS7` |
| WSUS-Ring / Wartungsring | `Set-OS7UpdateChannel -Channel stable\|preview\|development` |
| Update deinstallieren | `Restore-OS7` — geht auf die vorige Bootumgebung zurück |
| Systemwiederherstellungspunkt | `New-OS7BootEnvironment` |
| Wiederherstellungspunkte verwalten | `Get-/Remove-OS7BootEnvironment` |
| Abgesicherter Modus | im Bootmenü eine ältere Bootumgebung wählen |

> Der Unterschied zu Windows ist grundlegend: Ein Update in OS/7 verändert das
> laufende System **nicht**. Es befüllt eine Kopie und schaltet danach um. Es
> gibt deshalb keinen Zustand „halb aktualisiert".

## Verzeichnis

| Windows (RSAT / ActiveDirectory-Modul) | OS/7 |
|---|---|
| `Get-ADUser` | `Get-OS7ADUser` |
| `New-ADUser` | `New-OS7ADUser` |
| `Set-ADUser` | `Set-OS7ADUser` |
| `Get-ADGroup`, `Get-ADGroupMember` | `Get-OS7ADGroup`, `Get-OS7ADGroupMember` |
| `Add-ADGroupMember` | `Add-OS7ADGroupMember` |
| `Set-ADAccountPassword` | `Reset-OS7ADAccountPassword` |
| `Unlock-ADAccount`, `Enable-`/`Disable-ADAccount` | `Unlock-OS7ADAccount`, `Enable-`/`Disable-OS7ADAccount` |
| `Get-ADComputer`, `Get-ADOrganizationalUnit` | `Get-OS7ADComputer`, `Get-OS7ADOrganizationalUnit` |
| `Get-ADObject -LDAPFilter` | `Search-OS7AD -Filter` |
| `Add-Computer -DomainName` | `Join-OS7Domain` |
| `Test-ComputerSecureChannel` | `Test-OS7Domain` |
| `Reset-ComputerMachinePassword` | `Repair-OS7Domain` |
| `klist`, `klist purge` | `Get-OS7KerberosTicket`, `Remove-OS7KerberosTicket` |

Anders als unter Windows brauchen Sie für die Verzeichnisverwaltung **kein
Domänenmitglied**: `Enter-OS7AdminSession` öffnet eine Sitzung von jeder
OS/7-Maschine aus.

## Fernzugriff

| Windows | OS/7 |
|---|---|
| `Enter-PSSession -ComputerName` (WinRM) | `Enter-PSSession -HostName` (SSH) |
| `Invoke-Command -ComputerName` | `Invoke-Command -HostName` |
| `Enable-PSRemoting` | `Enable-OS7Remoting` |
| RDP | SSH; auf dem Desktop zusätzlich die üblichen Linux-Werkzeuge |

> WinRM gibt es hier nicht. `-ComputerName` existiert als Parameter und
> antwortet mit „no supported WSMan client library was found". SSH-basiertes
> Remoting ist PowerShells eigener Mechanismus und funktioniert auch von
> Windows aus.

## Was gleich geblieben ist

Diese Cmdlets funktionieren auf OS/7 unverändert und wurden deshalb bewusst
**nicht** nachgebaut:

`Get-Process` · `Stop-Process` · `Get-FileHash` · `Restart-Computer` ·
`Stop-Computer` · `Get-Date` · `Test-Connection` · `Get-Credential` ·
`Get-ChildItem` · `Copy-Item` · `Select-String` · `ConvertTo-Json` ·
`Invoke-RestMethod` · `Get-Content` · `Start-Job`

Ebenso die gesamte Sprache: Pipelines, `Where-Object`, `ForEach-Object`,
Format-Cmdlets, `Export-Csv`, Fehlerbehandlung, Skripte und Module.

## Was es hier nicht gibt

| Windows | Warum nicht |
|---|---|
| Gruppenrichtlinien / GPO-Editor | es gibt keine GPO-Engine für Linux |
| `repadmin`, `dcdiag`, `netdom` | RPC/DCOM; kein plattformübergreifender Client |
| DNS- und DHCP-Serververwaltung | dieselbe Ursache |
| `[ADSI]` | `System.DirectoryServices` lädt auf Linux und wirft dann „not supported on this platform". Ein Windows-Skript, das darauf aufsetzt, lässt sich nicht durch Kopieren portieren |
| WinRM | siehe oben |
