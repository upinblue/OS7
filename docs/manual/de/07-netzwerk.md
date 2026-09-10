# 7 Netzwerk

Unter der Oberfläche liegt **netplan**: eine Beschreibungsdatei sagt, was
gelten soll, und ein Renderer — `systemd-networkd` auf einem Server,
`NetworkManager` auf einem Desktop — setzt es um. Die OS/7-Cmdlets schreiben
diese Beschreibung, wenden sie an und **prüfen anschließend beim Kernel nach**,
ob dabei etwas herausgekommen ist.

## 7.1 Was da ist

```powershell
Get-OS7NetworkAdapter
```

![Die Adapter der Maschine, mit dem, was tatsächlich auf ihnen liegt.](images/60-adapters.png)

Die Ausgabe nennt Name, Typ, Treiber, MAC-Adresse, Verbindungszustand und die
Adressen, die der Kernel gerade hält. Mit `-Name` fragt man einen einzelnen
Adapter ab, mit `-IncludeLoopback` erscheint auch `lo`.

## 7.2 Konfiguriert und tatsächlich

```powershell
Get-OS7NetworkConfiguration | Format-List
```

![Zwei getrennte Antworten: was in netplan steht, und was auf der Maschine tatsächlich der Fall ist.](images/61-network-config.png)

Dies ist die Stelle, an der das Muster aus Kapitel 1.5 am meisten wert ist.
Der Befehl liefert **beides getrennt**:

* die **konfigurierte** Seite: die zusammengeführten netplan-Dateien, samt der
  Angabe, aus welchen Dateien welche Aussage stammt, und welcher Renderer
  zuständig ist;
* die **tatsächliche** Seite: die Adressen, Routen und Namensserver, die jetzt
  wirklich gelten.

Die Maschine, bei der beides auseinanderfällt, ist die interessante. Ein
häufiger Fall: eine netplan-Datei beschreibt einen Adapter, den es auf dieser
Maschine nicht gibt — etwa weil ein Datenträgerabbild von einem anderen
Gerät kam. netplan nimmt das wortlos hin und konfiguriert nichts. OS/7 meldet
es.

## 7.3 Einen Adapter einstellen

Auf DHCP:

```powershell
Set-OS7NetworkAdapter -Name enp0s31f6 -Dhcp
```

Auf eine feste Adresse:

```powershell
Set-OS7NetworkAdapter -Name enp0s31f6 `
    -Address 192.0.2.25/24 `
    -Gateway 192.0.2.1 `
    -Nameserver 192.0.2.10, 192.0.2.11 `
    -SearchDomain contoso.local
```

Was der Befehl tut, und die Reihenfolge ist der Punkt:

1. Die bisherige Konfiguration wird gesichert.
2. Die neue Beschreibung wird geschrieben und angewendet.
3. Der Befehl **wartet**, bis der Kernel eine Adresse auf dem Adapter meldet
   (`-TimeoutSeconds` steuert wie lange), und bei einer statischen
   Konfiguration auch auf das Gateway.
4. Kommt nichts hoch, wird **die alte Konfiguration zurückgeschrieben und
   erneut angewendet**.

Damit ist der klassische Fernwartungsunfall entschärft — eine falsche
statische Adresse trennt die Verbindung nicht dauerhaft, weil die Maschine von
selbst zurückgeht.

Eines darf dabei nie stillschweigend passieren: Wenn auch das Zurücknehmen
scheitert, sagt der Befehl das ausdrücklich. Ein Ergebnis mit
`RollbackFailed` ist eine Maschine, die eine Handbehandlung an der Konsole
braucht — und keine, die man ignoriert.

`-Force` überspringt die Rückfrage bei einem Adapter, über den die aktuelle
Sitzung läuft.

## 7.4 Erreichbarkeit prüfen

```powershell
Test-OS7Network | Format-List Ok,HasLink,DnsWorks
```

![Test-OS7Network prüft nicht nur, ob die Maschine „online" ist, sondern ob sie die Dienste erreicht, für die OS/7 gebaut ist.](images/62-test-network.png)

Die Einzelergebnisse je Endpunkt hängen als Eigenschaft daran:

```powershell
(Test-OS7Network).Endpoints | Format-Table -AutoSize
```

![Jeder geprüfte Endpunkt einzeln, mit dem Ergebnis.](images/63-endpoints.png)

Der Befehl geht die Kette durch — Verbindung, Gateway, Namensauflösung,
Endpunkte — und sagt, an welcher Stelle sie reißt. Das ist der Unterschied
zwischen „das Netz geht nicht" und „DNS antwortet, aber die Anmeldeendpunkte
sind blockiert".

Welche Endpunkte geprüft werden:

```powershell
Get-OS7Endpoint | Format-Table Name,Host,Port
```

![Die Endpunkte, die OS/7 kennt und prüfen kann.](images/64-endpoint-list.png)

Die Liste steht in einer Datendatei neben dem Modul, nicht im Code —
souveräne Clouds haben andere Hostnamen. Mit `-Cloud` prüft man gegen eine
andere Cloud, mit `-Endpoint` gezielt einzelne:

```powershell
Test-OS7Network -Endpoint Entra, Intune
Get-OS7Endpoint -Cloud UsGov
```

## 7.5 Fernwartung ohne Netz

Der Vollständigkeit halber: Falls eine Maschine über das Netz nicht mehr
erreichbar ist, funktioniert die gesamte Befehlsoberfläche auch über eine
serielle Konsole. Das ist kein Zufall, sondern eine Anforderung — jedes
Cmdlet in diesem Handbuch muss auf einer seriellen Leitung bedienbar sein.
