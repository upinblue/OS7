# 10 Die Verwaltungsebene: Entra ID, Intune und Azure Arc

OS/7 wird über Microsofts eigene Werkzeuge verwaltet. Drei davon, und sie sind
**drei getrennte Dinge** mit drei getrennten Antworten:

![Die drei Verwaltungswege und der eine Befehl, der alle drei abfragt.](images/diagram-management-de.svg)

## 10.1 Alles auf einmal

```powershell
Get-OS7ManagementStatus | Format-List
```

![Die drei Wege in einer Antwort, mit einer Zusammenfassung, die die erste Ursache nennt.](images/81-management.png)

Das ist der Befehl für die Übersicht. `Summary` nennt dabei nicht nur, dass
etwas fehlt, sondern **warum** — was in dieser Ecke der wichtigere Teil der
Antwort ist.

Mit `-SkipNetwork` unterbleibt die Erreichbarkeitsprüfung der Endpunkte; der
Befehl antwortet dann sofort und rein aus dem, was auf der Maschine liegt.

## 10.2 Entra ID — kann sich hier jemand anmelden

```powershell
Get-OS7EntraStatus | Format-List
```

![Ob sich ein Benutzer mit einem Entra-Konto anmelden kann — und wenn nein, an welchem Glied der Kette es liegt.](images/82-entra.png)

Die Anmeldung mit einem Entra-Konto läuft auf Ubuntu über **authd**, einen
Vermittler, der PAM mit OpenID Connect verbindet. Damit das funktioniert,
müssen drei Dinge stimmen:

1. `authd` ist installiert;
2. PAM ist auf `authd` verdrahtet;
3. es gibt einen **Broker** — das Stück, das tatsächlich mit Entra spricht.

Der dritte Punkt ist der, der in der Praxis fehlt, und sein Fehlen sieht wie
etwas ganz anderes aus: Ein Anmeldeversuch scheitert dann so, **als wäre das
Kennwort falsch**. Genau deshalb ist `Get-OS7EntraStatus` das erste, was man
auf einer Maschine fragt, an der sich niemand anmelden kann — es benennt das
fehlende Glied, statt eine Vermutung zu bestätigen.

## 10.3 Intune — ist das Gerät registriert

```powershell
Get-OS7IntuneEnrollment | Format-List
```

![Was sich über Intune auf dieser Maschine sagen lässt — und was nicht.](images/83-intune.png)

Der Befehl liest, was das Intune-Portal auf der Maschine hinterlegt: ob es
installiert ist, ob eine Registrierung vorliegt, wann sich das Gerät zuletzt
gemeldet hat.

Er sagt auch ausdrücklich, was er **nicht** beantworten kann. Der
Konformitätszustand eines Geräts wird im Mandanten ausgewertet, nicht auf dem
Gerät; eine Maschine, die behauptet, konform zu sein, wüsste das gar nicht. Wo
die Antwort nur im Mandanten liegt, wird das gesagt statt geraten.

Intune-Registrierung und -Portal gibt es auf **amd64**; auf arm64 liefert
Microsoft sie nicht.

## 10.4 Azure Arc — ist die Maschine inventarisiert

```powershell
Get-OS7ArcStatus | Format-List
```

![Ob der Azure-Connected-Machine-Agent installiert ist und was er über sich sagt.](images/84-arc.png)

Arc bringt eine Maschine als Ressource in Azure, ohne dass sie in Azure läuft
— für Inventar, Richtlinien und Update-Verwaltung. `Get-OS7ArcStatus` fragt
den Agenten `azcmagent` selbst, statt aus der Existenz einer Datei zu
schließen, dass er verbunden ist.

> Der Zustand des Agenten liegt **außerhalb** der Bootumgebung. Ein Rollback
> nimmt eine Arc-Anbindung also nicht zurück — und das ist gewollt, denn Azure
> rollt nicht mit zurück.

## 10.5 Wenn die Verwaltung nicht greift

Die Reihenfolge, in der man fragt, weil jede Stufe die nächste voraussetzt:

```powershell
Get-OS7TimeSynchronization      # 1. geht die Uhr richtig?
Test-OS7Network                 # 2. kommt die Maschine überhaupt hinaus?
Test-OS7Network -Endpoint Entra, Intune, Arc   # 3. erreicht sie die richtigen Endpunkte?
Get-OS7ManagementStatus         # 4. und was sagen die drei Wege selbst?
```

Die Uhr steht bewusst an erster Stelle. Eine abweichende Uhr bringt jede
Token-basierte Anmeldung zu Fall, und die Fehlermeldung, die dabei entsteht,
weist in eine völlig andere Richtung.

## 10.6 Was hier bewusst fehlt

**Gruppenrichtlinien.** Es gibt keine GPO-Engine für Linux. Ein
domänenbeigetretener Rechner kann Anmelderechte aus Richtlinien
**durchsetzen** — das ist Konsum, keine Verwaltung.

**Alles über RPC oder DCOM.** `repadmin`, `dcdiag`, `netdom`, die Verwaltung
von DNS- und DHCP-Servern, die Zertifikatanforderung: dafür gibt es keinen
plattformübergreifenden Client.
