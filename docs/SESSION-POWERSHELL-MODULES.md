# OS/7 — welche PowerShell-Adminmodule mitgeliefert werden, gemessen

**Gemessen 2026-08-25.** Ausgangsfrage: welche Adminmodule gehören ins Image,
wie kommen sie hinein, wie hängen sie am Releasezug — und womit schreibt und
startet man PowerShell-Skripte ohne GUI.

Nichts davon ist implementiert. Dieses Dokument ist die Messung, nicht die
Entscheidung; die Entscheidung gehört nach README "Locked decisions" und in
einen Modulblock in [../build/config/os7-release.conf](../build/config/os7-release.conf).

Alle Zahlen unten stammen aus tatsächlich heruntergeladenen Paketen der
PowerShell Gallery und aus dem **gepinnten** Ubuntu-Snapshot
`20260824T000000Z`, nicht aus Dokumentation.

---

## 1. Vier Messungen, die die Auswahl entschieden haben

### M1 — Die Teams-Lizenz verbietet die Weitergabe

`MicrosoftTeams` 7.9.0 bringt `LICENSE.txt` mit. Wörtlich, erste Zeile:

> "Your use of the Microsoft Teams PowerShell is subject to the terms and
> conditions of the agreement you agreed to when you signed up for the Microsoft
> Teams subscription and by which you acquired a license for the software."

und weiter: *"You may not use the service or software if you have not validly
acquired a license from Microsoft or its licensed distributors."*

Das ist eine Abonnement-gebundene Nutzungslizenz ohne Weitergaberecht. Ein ISO,
das dieses Modul enthält, verteilt es an jeden, der das ISO bekommt — auch an
Leute ohne Teams-Abo. **Teams kann nicht ins Image.** Das Modul selbst läuft
unter Linux/PS7 einwandfrei; die Schranke ist juristisch, nicht technisch.

### M2 — Exchange Online ist MIT, entgegen seiner eigenen `licenseUrl`

`ExchangeOnlineManagement` 3.10.1 zeigt in der Gallery
`licenseUrl = http://aka.ms/azps-license` — das ist die Datei von *Azure
PowerShell* und sieht nach fremdem Boilerplate aus. Im Paket selbst liegt
`license.txt`, und die sagt etwas anderes:

> "MIT License 2.0 / Copyright (c) 2019 Exchange Online Manageability Team /
> Permission is hereby granted, free of charge … to deal in the Software without
> restriction, including without limitation the rights to use, copy, modify,
> merge, publish, distribute, sublicense, and/or sell copies of the Software."

Das ist der MIT-Wortlaut. **EXO darf mitgeliefert werden**, mit Lizenztext
daneben. Nebenbei: `aka.ms/azps-license` selbst ist ebenfalls kein EULA — die
Datei trägt eine Microsoft-Kopfzeile und darunter ab `START OF LICENSE` die
**Apache License 2.0** plus Drittanbieterhinweise.

Die Konsequenz für den Rest des Repos: **die `licenseUrl` eines Gallery-Pakets
ist kein Beleg.** Was im Paket liegt, gilt.

### M3 — `Microsoft.Entra` ist ein Wrapper, kein Modul

Die Entra-Modulfamilie wirkt winzig und ist es auch — bis man die Abhängigkeiten
auflöst. `Microsoft.Entra.Users.psd1` trägt:

```
RequiredModules = @(@{ModuleName = 'Microsoft.Graph.Users'; ModuleVersion = '2.25.0'}, …)
```

| | installiert |
|---|---|
| Die 9 `Microsoft.Entra.*`-Module selbst | **5,0 MB** |
| Die 9 `Microsoft.Graph.*`-Module, die sie voraussetzen | **311 MB** |

Aufgelöst aus den `.nuspec`-Dependencies aller neun Wrapper und dann einzeln
heruntergeladen: `Applications` 24, `Authentication` 39, `Groups` 25,
`Identity.DirectoryManagement` 28, `Identity.Governance` 119,
`Identity.SignIns` 31, `Reports` 8, `Users` 29, `Users.Actions` 8 MB.

"Wir liefern nur Entra aus, das ist ja klein" wäre also um Faktor 60 falsch
gewesen.

### M4 — Die Größen sind auf der ISO fast umsonst, auf der Platte nicht

Der Inhalt dieser Module ist ganz überwiegend **generierter PowerShell-Text**
(`exports/`), und der komprimiert extrem gut. Gemessen mit `tar | xz -9`, also
grob dem, was SquashFS daraus macht:

| Bündel | installiert | xz -9 |
|---|---|---|
| Kern (EXO + PnP + Graph.Authentication + Secret* + Editor-Server) | 162 MB | **26 MB** |
| Entra + seine Graph-Abhängigkeiten | 315 MB | **21 MB** |
| Intune (`Graph.DeviceManagement` + `.Administration`) | 42 MB | **3 MB** |
| **Summe** | **~520 MB** | **~50 MB** |

Auf ein ~2 GB großes ISO sind das **+2,5 %**. Der Preis steht nicht auf dem
Medium, sondern im installierten System: eine halbe GB pro Boot-Environment,
und ein BE-System hält mehrere. Das ist das Argument, das über die Auswahl
entscheidet — nicht die ISO-Größe.

---

## 2. Was auf jeder Plattform Ballast ist — und wie viel

Jedes dieser Pakete liefert Windows-Anteile mit, die auf OS/7 per Definition tot
sind: `netFramework/`, `net4xx/`, `Desktop/`, `runtimes/win-*`.

| Modul | Version | voll | Linux-Anteil |
|---|---|---|---|
| ExchangeOnlineManagement | 3.10.1 | 64 MB | **31 MB** |
| MicrosoftTeams | 7.9.0 | 80 MB | 49 MB |
| PnP.PowerShell | 3.4.1 | 83 MB | **74 MB** |
| Microsoft.Graph.Authentication | 2.39.0 | 39 MB | **36 MB** |
| Az.Accounts | 5.5.2 | 30 MB | **29 MB** |
| PSScriptAnalyzer | 1.25.0 | 286 MB | **7,5 MB** |

Die letzte Zeile ist kein Tippfehler. **278 der 286 MB sind
`compatibility_profiles/`** — JSON-Profile, aus denen die `PSUseCompatible*`-Regeln
lernen, welche Cmdlets es in Windows PowerShell 5.1 und in älteren Windows-Builds
gab. Auf einem reinen PS7-Linux-System prüfen diese Regeln nichts.

Dasselbe noch einmal beim Editor-Sprachserver: `PowerShellEditorServices.zip`
4.7.0 ist 19,5 MB, entpackt **299 MB** — weil es PSScriptAnalyzer 1.25.0 mit
genau diesem Verzeichnis bündelt. Ohne das Verzeichnis: **20 MB.**

---

## 3. Die Lücken, die ein Admin bemerken wird

Alle gegen Microsofts Livedokumentation vom 2026-08-25 geprüft.

| # | Lücke | Beleg |
|---|---|---|
| L-M1 | **Security & Compliance PowerShell gibt es unter Linux nicht.** `Connect-IPPSSession` fehlt, also kein DLP, keine Aufbewahrung, kein eDiscovery per Skript. | Learn, "Linux support for the module": *"Currently, **Connect-IPPSSession** and therefore Security & Compliance PowerShell isn't available in PowerShell 7 on Linux clients."* Gleicher Satz gilt für macOS. |
| L-M2 | **Ubuntu 26.04 steht nicht in Microsofts Supportmatrix für EXO.** Gelistet sind 18.04, 20.04, 22.04, 24.04. | Dieselbe Seite. Technisch wird es laufen — es ist .NET; "offiziell unterstützt" ist es nicht. Dieselbe Form wie offene Frage 2 (Arc auf 26.04). |
| L-M3 | **`-CertificateThumbprint` funktioniert nicht.** Der Parameter liest den Windows-Zertifikatspeicher. Unbeaufsichtigte Automatisierung braucht auf Linux `-CertificateFilePath` + `-CertificatePassword` (also eine PFX-Datei auf der Platte) oder Azure Key Vault. | Learn, Release-Historie zur CBA-GA. Das hängt direkt an **U8** (wo liegt der Wiederherstellungsschlüssel) — es ist dieselbe Frage in anderer Kleidung, und `SecretManagement`/`SecretStore` sind die Antwortstelle. |
| L-M4 | **PnP.PowerShell braucht eine eigene Entra-App-Registrierung.** Die Multi-Tenant-App "PnP Management Shell" wurde am 2024-09-09 gelöscht. Erster Kontakt mit SharePoint ist also ein `Register-PnPEntraIDApp` im Kundentenant, kein `Connect-PnPOnline`. | PnP-Doku und Ankündigung. Gehört in die Ersteinrichtungsdoku, nicht in eine Fehlermeldung. |
| L-M5 | **Kein On-Prem-AD.** Das `ActiveDirectory`-Modul ist RSAT, also Windows-only, und hat keinen plattformübergreifenden Ersatz. Bleibt Remoting auf einen Windows-Host. | — |
| L-M6 | **EXO ≥ 3.10 verlangt pwsh ≥ 7.6.0** (.NET-10-Assemblies). Der Pin steht auf 7.6.5, passt also — aber eine Rückstufung von PowerShell wäre ab jetzt ein Modulbruch. | Learn, "Supported operating systems". Gehört als Kopplung in die Release-Stückliste. |

---

## 4. Der Pfad, an dem man sich verletzt

`$PSHOME/powershell.config.json` kann `PSModulePath` setzen — das ist der
saubere, dokumentierte Weg, einen eigenen Modulpfad systemweit und **auch für
nichtinteraktive Sitzungen** (systemd-Timer, Intune-Skripte) gültig zu machen.
Zwei Sätze aus `about_PowerShell_Config` machen ihn zur Falle:

> "**Overrides** the `PSModulePath` settings for this PowerShell session. If the
> configuration is for all users, sets the **AllUsers** module path."

> "Configuring an **AllUsers** or **CurrentUser** module path here doesn't change
> the scoped installation location for PowerShellGet cmdlets like
> `Install-Module`. These cmdlets always use the *default* module paths."

Zusammen heißt das: wer `"PSModulePath": "/usr/lib/os7/psmodules"` schreibt,
**ersetzt** `/usr/local/share/powershell/Modules` — und `Install-PSResource
-Scope AllUsers` installiert danach weiterhin dorthin, wo nun niemand mehr sucht.
Der Admin installiert ein Modul, bekommt keinen Fehler, und `Import-Module`
findet es nicht.

Beide Pfade müssen also drinstehen, und die Reihenfolge ist eine Entscheidung:
`Import-Module` nimmt das **erste** Verzeichnis mit passendem Namen und darin die
höchste Version. `/usr/local/...` zuerst heißt: ein Admin, der bewusst eine
neuere Version installiert, gewinnt — und `Get-OS7Version` meldet die
Überdeckung als Drift, statt sie zu verhindern. Das ist dieselbe Haltung wie
Release-Plan §5 gegenüber `apt`.

---

## 5. Was das am Updatekonzept ändert

Nichts am Mechanismus, drei Dinge an den Rändern.

1. **Module sind Stückliste, nicht Zusatz.** Version und SHA256 gehören nach
   `os7-release.conf` und in den `components`-Block von `release.json`, nach dem
   Muster von Hook 0020 — PSGallery hat so wenig einen Snapshot-Dienst wie
   `packages.microsoft.com` (Release-Plan §3.4, Drift-Loch 3).
2. **Liegen sie im BE, ist der Rest schon gebaut.** `Update-OS7` klont, füllt,
   aktiviert; `Restore-OS7` nimmt die Module mit zurück. Ein Modul-Bump ist ein
   **Minor**, weil er Funktionalität ändert.
3. **Die Driftmeldung deckt sie heute nicht ab.** `packages_manifest` ist der
   Hash von `dpkg --get-selections`; Module sind lose Dateien und kommen darin
   nicht vor. Ohne ein zweites Manifest über den Modulbaum meldet
   `Get-OS7Version` "1.0.0.0" für ein System, dessen Adminwerkzeug ausgetauscht
   wurde. Genau der Fall, den §5 "schlimmer als keine Nummer" nennt.

Und eine Folge für **U6**, die dort noch nicht steht: nach der Regel *"ein Pfad
gehört ins BE, wenn ein Rollback das System korrekter macht"* gehört
`/usr/local/share/powershell/Modules` **nach draußen**, auf `rpool/DATA`. Was
ein Admin selbst installiert hat, ist nicht Eigentum des Release, und ein
Rollback, der die eigenen Werkzeuge des Admins stillschweigend entfernt, ist
dieselbe Klasse Fehler wie das zurückgerollte `/var/lib/<service>`.

Das erzwingt, dass die OS/7-eigenen Module dort **weg** müssen: `powershell/OS7`
und `powershell/Zfs` werden heute von `build.sh` genau dorthin gelegt. Sie sind
Release und gehören ins BE.

---

## 6. Was NICHT gemessen wurde

* **Nichts wurde gebootet.** Kein Modul wurde auf OS/7 importiert, keine
  Verbindung zu einem Tenant aufgebaut. Alle Aussagen oben sind über Pakete,
  Lizenzen und Dokumentation — nicht über einen laufenden Rechner.
* **Az** über `Az.Accounts` hinaus. Das volle `Az` liegt im GB-Bereich; welche
  Teilmodule ein Arc-verwalteter Server wirklich braucht, ist ungemessen.
* **Die Graph-Abhängigkeitsmenge** wurde aus `.nuspec`-Dependencies aufgelöst,
  nicht durch ein echtes `Install-PSResource`. Transitiv tiefer liegende
  Abhängigkeiten können fehlen.
* **PSES gegen pwsh 7.6.5.** Der Sprachserver ist gemessen und lizenzgeprüft;
  dass er unter der gepinnten PowerShell-Version startet, ist nicht gezeigt.
  Er enthält keinerlei native Anteile (`.so`/`.dylib`/`runtimes/` fehlen
  vollständig), ein Bündel bedient also beide Architekturen — das ist gemessen.
* **Ob 500 MB pro Boot-Environment akzeptabel sind.** Der ZFS-Kompressionsfaktor
  auf diesem Inhalt ist nicht gemessen; `xz -9` ist keine Vorhersage für LZ4.

---

## 7. Der Editor

Gemessen gegen den gepinnten Snapshot `20260824T000000Z`, `binary-arm64`:

| Paket | Komponente | .deb | installiert |
|---|---|---|---|
| `neovim` 0.11.6-1 | universe | 2 988 470 B | 9,5 MB |
| `micro` 2.0.15-2 | universe | 4 209 888 B | 13,8 MB |
| `emacs-nox` 1:30.2+1-2ubuntu1 | universe | 8 081 320 B | 51,6 MB |
| `nano` 8.7.1-1 | main | 294 762 B | 0,9 MB |
| `vim` 2:9.1.2141-1ubuntu4 | main | 1 956 418 B | 4,5 MB — **ist schon drin** |
| `helix` | **nicht im Archiv** | — | — |

Dazu `PowerShellEditorServices` 4.7.0 — MIT, von Microsoft, derselbe
Sprachserver, den die PowerShell-Erweiterung in VS Code fährt. Getrimmt 20 MB,
ohne native Anteile.

Helix scheidet damit aus demselben Grund aus, aus dem im August 2026 schon
dash-to-panel und ArcMenu ausgeschieden sind: **es kommt nicht aus dem Pin.**
Es hätte außerdem keinen voreingestellten Sprachserver und keinen Debugger;
PowerShell-Syntaxhervorhebung hat es inzwischen.

Neovim 0.11 braucht für LSP **kein** Fremd-Plugin mehr (`vim.lsp.config` /
`vim.lsp.enable` sind eingebaut), was eine OS/7-eigene Konfiguration auf ~40
Zeilen Lua und null externe Abhängigkeiten bringt. Debugging (DAP) wäre der
einzige Teil, der ein Fremd-Plugin verlangt.
