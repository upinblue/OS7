# 8 Zeit

Die Uhr ist auf OS/7 kein Nebenschauplatz, sondern eine Voraussetzung.
Kerberos verweigert ein Ticket, dessen Zeitstempel mehr als **fünf Minuten**
von der Uhr des Domänencontrollers abweicht — und eine abweichende Uhr meldet
kein Uhrproblem. Sie meldet, dass das Kennwort falsch sei.

Deshalb steht dieses kurze Kapitel vor den Kapiteln über Verwaltung und
Verzeichnis, und deshalb ist die Fünf-Minuten-Grenze in `Get-OS7TimeSynchronization`
fest eingebaut.

Die Zeitsynchronisation macht **chrony**, nicht `systemd-timesyncd`.

## 8.1 Wie spät ist es

```powershell
Get-OS7Time | Format-List
```

![Die Uhr: lokale Zeit, UTC, Zeitzone, und ob die Hardware-Uhr in Ortszeit läuft.](images/70-time.png)

Das letzte Feld ist die Frage, die auf einer Maschine mit
Windows-Doppelinstallation zählt: Windows führt die Hardware-Uhr
üblicherweise in Ortszeit, Linux in UTC. Stimmen die Annahmen nicht überein,
springt die Uhr bei jedem Wechsel.

## 8.2 Wird die Uhr überhaupt gestellt

```powershell
Get-OS7TimeSynchronization | Format-List
```

![Ob die Uhr diszipliniert wird, von wem, wie weit sie abweicht — und ob das für eine Anmeldung reicht.](images/71-time-sync.png)

Der Befehl unterscheidet **drei** Ergebnisse, und die Unterscheidung ist der
Grund, warum er existiert:

| Ergebnis | Bedeutung |
|---|---|
| `$null` | chronyd konnte nicht gefragt werden — der Dienst läuft nicht |
| `$false` | chronyd wurde gefragt und diszipliniert die Uhr **nicht** |
| `$true` | die Uhr wird diszipliniert |

„Konnte nicht gefragt werden" und „antwortet mit nein" sind verschiedene
Zustände mit verschiedenen Ursachen. Ein Befehl, der beide als „nicht
synchron" zusammenfasste, würde einen abgestürzten Dienst und eine fehlende
Netzverbindung ununterscheidbar machen.

Dazu kommt die Abweichung selbst und die Aussage, ob sie innerhalb der
Kerberos-Toleranz liegt.

## 8.3 Zeitzone setzen

```powershell
Set-OS7TimeZone -Id Europe/Berlin
```

Der Befehl schreibt den Symlink, der die Zeitzone tatsächlich bestimmt, und
liest ihn zurück. Gültige Bezeichner sind die der IANA-Datenbank
(`Europe/Berlin`, `America/New_York`, `UTC`).

## 8.4 Zeitserver setzen

```powershell
Set-OS7TimeSynchronization -NtpServer dc01.contoso.local, dc02.contoso.local
```

In einer Active-Directory-Umgebung sind die Domänencontroller die richtigen
Zeitquellen — sie sind die Uhr, gegen die Kerberos rechnet.

Ein Pool statt einzelner Server:

```powershell
Set-OS7TimeSynchronization -Pool de.pool.ntp.org
```

`-Exclusive` ersetzt alle bisherigen Quellen, statt die neuen zu ergänzen.

Die Server landen in einer eigenen Datei unter `chrony`s
`sources.d`-Verzeichnis, nicht in `chrony.conf`. Anschließend wird chrony zum
Neulesen aufgefordert — der Dienst wird **nicht** neu gestartet, weil ein
Neustart die bereits erreichte Synchronisation verwirft.

## 8.5 Uhr sofort korrigieren

Normalerweise zieht chrony eine falsche Uhr langsam nach (*slew*), damit keine
Zeitsprünge entstehen. Nach einem langen Stillstand ist das zu langsam:

```powershell
Sync-OS7Time
```

Das weist chrony an, die Uhr **jetzt** zu setzen, wartet die Einschwingzeit ab
(`-SettleSeconds`) und meldet, was tatsächlich passiert ist.

## 8.6 Reihenfolge bei Anmeldeproblemen

Wenn eine Anmeldung gegen die Domäne mit „falsches Kennwort" scheitert,
obwohl das Kennwort stimmt, ist dies die Reihenfolge:

```powershell
Get-OS7TimeSynchronization      # wird die Uhr überhaupt gestellt?
Get-OS7Time                     # und stimmt sie?
Test-OS7Directory -Domain contoso.local   # misst die Abweichung gegen den DC
```

`Test-OS7Directory` misst die Abweichung gegen die Uhr des
Domänencontrollers selbst — und das ist die Zahl, auf die es ankommt, nicht
die Abweichung gegen irgendeinen Zeitserver.
