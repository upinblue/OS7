# 11 Active Directory

Es gibt **zwei völlig verschiedene Dinge**, die man mit Active Directory tun
kann, und sie werden regelmäßig verwechselt. OS/7 trennt sie strikt:

![Verwalten und Mitglied werden sind unabhängig voneinander.](images/diagram-active-directory-de.svg)

**Verwalten** heißt: Ein Administrator meldet sich **von** einer OS/7-Maschine
aus mit seinem eigenen AD-Konto am Verzeichnis an und arbeitet als er selbst —
legt Benutzer an, pflegt Gruppen, setzt Kennwörter zurück. Dafür ist die
Maschine **kein Domänenmitglied**, sie braucht kein Computerkonto und kein
zusätzliches Paket. Es ist eine ausgehende LDAPS-Verbindung und sonst nichts.

**Mitglied werden** heißt: Die Maschine selbst bekommt ein Computerkonto in
der Domäne, damit sich Domänenbenutzer **an ihr** anmelden können.

Wer nur Verzeichnisobjekte pflegen will, braucht das Zweite nicht.

## 11.1 Vorbereitung: das Zertifikat des Domänencontrollers

Die Verbindung geht über **LDAPS auf Port 636**, und das ist keine
Voreinstellung, sondern der einzige Weg: Active Directory lehnt eine einfache
Bindung auf Port 389 ab, und die Signierung-und-Versiegelung, die ein
Windows-Client stattdessen benutzt, gibt es auf Linux nicht.

Damit die Maschine das Zertifikat des Domänencontrollers akzeptiert, muss die
ausstellende Zertifizierungsstelle bekannt sein:

```powershell
Add-OS7DirectoryTrust -Path /pfad/zur/contoso-ca.crt -Name contoso-issuing-ca
```

Der Befehl legt das Zertifikat maschinenweit ab und **liest anschließend
zurück**, dass es angekommen ist.

Ob die Voraussetzungen stimmen:

```powershell
Test-OS7Directory -Domain contoso.local
```

Der Befehl geht die Kette durch — DNS, Erreichbarkeit, TLS, Bindung — und sagt,
welches Glied fehlt. Er misst dabei auch die **Zeitabweichung gegen die Uhr des
Domänencontrollers**; siehe Kapitel 8.

## 11.2 Anmelden

```powershell
Enter-OS7AdminSession -Domain contoso.local
```

Der Befehl fragt nach den Anmeldedaten und öffnet eine Sitzung **für diese
Shell**. Mit `-Credential` übergibt man sie vorbereitet, mit `-Server` einen
bestimmten Domänencontroller statt des per DNS gefundenen.

```powershell
Get-OS7AdminSession
```

Beachten Sie, was hier gemeldet wird: **die Identität, die der Server
zurückgibt** — nicht der Name, mit dem man sich angemeldet hat. Eine Bindung,
die keine Ausnahme ausgelöst hat, ist noch kein Nachweis, wer man ist; ein
stiller Rückfall auf eine anonyme Bindung sähe sonst wie ein Erfolg aus.

Die Sitzung beenden:

```powershell
Exit-OS7AdminSession
```

> **Die Anmeldedaten werden benutzt und dann vergessen.** Es gibt keine
> Sitzung, die sich später von selbst neu anmelden kann — das wäre ein
> gespeichertes Kennwort. Nach einem Neustart der Shell meldet man sich erneut
> an.

## 11.3 Benutzer

```powershell
Get-OS7ADUser -Identity mmustermann
Get-OS7ADUser -Filter '(department=Vertrieb)' -SearchBase 'OU=Berlin,DC=contoso,DC=local'
Get-OS7ADUser -Identity mmustermann -Property department, manager, lastLogonTimestamp
```

`Enabled` und `LockedOut` sind **getrennte Antworten aus getrennten Quellen**.
Ein gesperrtes Konto ist nicht dasselbe wie ein deaktiviertes, und die
Verwechslung führt zu Behebungsversuchen, die nichts bewirken.

Ein Konto anlegen:

```powershell
$pw = Read-Host -AsSecureString -Prompt 'Kennwort'
New-OS7ADUser -Name mmustermann `
    -Path 'OU=Berlin,DC=contoso,DC=local' `
    -DisplayName 'Max Mustermann' `
    -GivenName Max -Surname Mustermann `
    -UserPrincipalName mmustermann@contoso.local `
    -Mail mmustermann@contoso.local `
    -Password $pw -Enabled
```

Die Reihenfolge dahinter ist erzwungen und nicht gewählt: Active Directory
legt ein Konto zunächst **deaktiviert** an, nimmt danach das Kennwort entgegen
und lässt es erst dann aktivieren. Ein Konto, das mit Kennwort und aktiviert
in einem Zug angelegt werden soll, wird abgelehnt.

Ändern, sperren, entsperren:

```powershell
Set-OS7ADUser -Identity mmustermann -Department Vertrieb
Disable-OS7ADAccount -Identity mmustermann
Enable-OS7ADAccount  -Identity mmustermann
Unlock-OS7ADAccount  -Identity mmustermann
```

`Enable-` und `Disable-` lesen die vorhandenen Kennzeichen und ändern
**genau ein Bit**. Sie schreiben nicht den ganzen Wert neu, damit nichts
anderes dabei verlorengeht.

Kennwort zurücksetzen:

```powershell
$pw = Read-Host -AsSecureString -Prompt 'Neues Kennwort'
Reset-OS7ADAccountPassword -Identity mmustermann -NewPassword $pw -MustChangeAtNextLogon
```

Über eine unverschlüsselte Verbindung verweigert der Befehl den Dienst,
**bevor** das Kennwort auf die Leitung geht.

## 11.4 Gruppen

```powershell
Get-OS7ADGroup -Identity 'Vertrieb-Berlin'
Get-OS7ADGroupMember -Identity 'Vertrieb-Berlin'
Get-OS7ADGroupMember -Identity 'Vertrieb-Berlin' -Recursive

New-OS7ADGroup -Name 'Vertrieb-Berlin' -Path 'OU=Gruppen,DC=contoso,DC=local' -Scope Global

Add-OS7ADGroupMember    -Identity 'Vertrieb-Berlin' -Member mmustermann, jschmidt
Remove-OS7ADGroupMember -Identity 'Vertrieb-Berlin' -Member jschmidt
```

`-Recursive` benutzt die Vergleichsregel des Verzeichnisses selbst, statt die
Verschachtelung im Client nachzubauen. Und `Add-OS7ADGroupMember` fügt hinzu —
es ersetzt die Mitgliederliste nicht.

## 11.5 Computer und Organisationseinheiten

```powershell
Get-OS7ADComputer -Identity WS-BER-014
Get-OS7ADComputer -Filter '(operatingSystem=*Server*)'
Get-OS7ADOrganizationalUnit -SearchBase 'DC=contoso,DC=local'
Move-OS7ADObject -DistinguishedName 'CN=WS-BER-014,CN=Computers,DC=contoso,DC=local' `
                 -TargetPath 'OU=Berlin,DC=contoso,DC=local'
Rename-OS7ADObject -DistinguishedName 'CN=alt,OU=…' -NewName neu
```

Das abschließende `$` eines Computerkontos muss niemand tippen.

## 11.6 Wenn die kuratierte Oberfläche nicht reicht

Eine Verzeichnisoberfläche, aus der man nicht herauskommt, müsste vollständig
sein. Deshalb liegt der Rohzugriff daneben:

```powershell
Search-OS7AD -Filter '(&(objectClass=user)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))' `
             -SearchBase 'DC=contoso,DC=local' -Scope Subtree

Get-OS7ADObject -DistinguishedName 'CN=Max Mustermann,OU=Berlin,DC=contoso,DC=local'
Set-OS7ADObject -DistinguishedName 'CN=Max Mustermann,OU=…' -Name extensionAttribute1 -Value 'X'
Remove-OS7ADObject -DistinguishedName 'CN=alt,OU=…'
```

Suchen folgen den Seiten bis zum Ende — ein Ergebnis wird nie stillschweigend
bei 1000 Objekten abgeschnitten.

## 11.7 Der Domänenbeitritt

Damit sich **Domänenbenutzer an dieser Maschine** anmelden können, tritt sie
der Domäne bei:

```powershell
$pw = Read-Host -AsSecureString -Prompt 'Kennwort des Beitrittskontos'
Join-OS7Domain -Domain contoso.local `
    -UserName beitritt `
    -Password $pw `
    -OrganizationalUnit 'OU=Linux,OU=Server,DC=contoso,DC=local' `
    -AllowGroup 'CONTOSO\Linux-Benutzer' `
    -AdministratorGroup 'CONTOSO\Linux-Administratoren'
```

`-AllowGroup` bestimmt, wer sich anmelden darf; `-AdministratorGroup`, wer die
Maschine verwalten darf. Die daraus erzeugte `sudo`-Regel wird von `visudo`
geprüft, bevor sie gültig wird — eine fehlerhafte Regel würde sonst jede
Rechteerhöhung auf der Maschine unbrauchbar machen.

Das Kennwort geht über die **Standardeingabe** an das Beitrittswerkzeug, nie
als Argument; ein Argument stünde in der Prozessliste.

Zustand und Prüfung:

```powershell
Get-OS7Domain | Format-List
Test-OS7Domain -Domain contoso.local
```

![Ob diese Maschine Mitglied einer Domäne ist — konfiguriert und tatsächlich.](images/a0-domain.png)

`Get-OS7Domain` beantwortet wieder beide Hälften: was hinterlegt ist, und was
tatsächlich gilt. `Test-OS7Domain` prüft, ob die Mitgliedschaft **funktioniert**
— ob sich ein Verzeichniskonto über die Namensauflösung des Systems auflösen
lässt. Das ist die einzige Frage, deren Antwort einen funktionierenden Beitritt
beweist.

Anmelderichtlinie nachträglich ändern:

```powershell
Get-OS7DomainLogonPolicy
Set-OS7DomainLogonPolicy -AdministratorGroup 'CONTOSO\Linux-Administratoren'
```

Nach einem **Rollback** kann das Maschinenkonto veraltet sein, weil die Domäne
das Kennwort inzwischen gewechselt hat und die Bootumgebung den alten Stand
zurückgebracht hat:

```powershell
Repair-OS7Domain -Domain contoso.local
```

Austreten:

```powershell
Remove-OS7Domain -Domain contoso.local -UserName beitritt -Password $pw
```

## 11.8 Kerberos-Tickets

```powershell
Get-OS7KerberosTicket
New-OS7KerberosTicket -Principal administrator@CONTOSO.LOCAL
Remove-OS7KerberosTicket
```

![Die Kerberos-Tickets dieser Sitzung.](images/a2-kerberos.png)

Der Realm wird großgeschrieben — das ist Kerberos-Konvention und keine
Freiheit.

> **Home-Verzeichnisse von Domänenbenutzern liegen außerhalb der
> Bootumgebung**, genau wie die lokalen. Andernfalls nähme ein Rollback die
> Dateien angemeldeter Domänenbenutzer mit zurück.
