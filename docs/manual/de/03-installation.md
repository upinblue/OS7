# 3 Eine Maschine installieren

Installiert wird mit **`os7-setup`**, dem Textmodus-Installer von OS/7. Er
startet vom Installationsmedium automatisch und braucht keine Grafikkarte,
keine Maus und kein Netzwerk.

## 3.1 Was Setup anlegt

Bevor Sie die erste Taste drücken, lohnt es sich zu wissen, was am Ende auf
dem Datenträger steht — denn diese Aufteilung ist der Grund, warum Updates
später zurückrollbar sind:

![Der Datenträger nach der Installation. Entscheidend ist, was innerhalb und was außerhalb der Bootumgebung liegt.](images/diagram-disk-de.svg)

Drei Partitionen:

* eine **EFI-Systempartition** (512 MB, FAT32) — unverschlüsselt, weil die
  Firmware sie lesen können muss;
* ein **Bootpool** `bpool` (2 GB, ZFS) — unverschlüsselt, weil GRUB ihn lesen
  können muss, und mit einem eingeschränkten Merkmalssatz, den GRUB versteht;
* der Rest als **LUKS2-Container**, und darin der ZFS-Pool `rpool`.

Verschlüsselt wird mit **LUKS2 unter ZFS**, nicht mit ZFS-eigener
Verschlüsselung. Das ist eine bewusste Entscheidung: LUKS ist das, was
Microsofts Verwaltungswerkzeuge auf Linux als Datenträgerverschlüsselung
erkennen und melden.

## 3.2 Die Bildschirme, der Reihe nach

### 1 — Willkommen

![Der erste Bildschirm. Die Version steht auf jedem Bildschirm oben rechts.](images/setup-01-welcome.png)

`ENTER` installiert, `R` repariert eine vorhandene Installation, `F3` bricht
ab. Mit `F5` schaltet Setup auf ein kontrastreicheres Farbfeld um — gedacht
für Fernwartungsfenster und schlechte Bildschirme.

![Dasselbe Bild mit F5: dunkleres Feld, gleiche Bedienung.](images/setup-01-welcome-high-contrast.png)

### 2 — Lizenz

![Die Lizenzbedingungen, seitenweise mit BILD-AUF und BILD-AB.](images/setup-02-licence.png)

`F8` stimmt zu, `ESC` lehnt ab.

### 3 — Regionale Einstellungen

![Sprache, Tastaturbelegung und Zeitzone in einem Bildschirm.](images/setup-03-regional.png)

Die Auswahl hier bestimmt die Sprache des installierten Systems, die
Tastaturbelegung der Konsole und die Zeitzone. Die Zeitzone lässt sich später
mit `Set-OS7TimeZone` ändern.

### 4 — Datenträger auswählen

![Die Datenträger der Maschine. Das Installationsmedium ist aufgeführt und nicht auswählbar.](images/setup-04-disk.png)

Setup listet alle Datenträger und sagt bei jedem, was darauf ist. Ein
Datenträger, der bereits eine OS/7-Installation trägt, wird als solcher
erkannt. Das Installationsmedium selbst erscheint in der Liste, ist aber
gesperrt — sichtbar, damit niemand rätselt, wo es geblieben ist.

### 5 — Aufteilung und Verschlüsselung

![Die Aufteilung im Überblick, mit Verschlüsselung und Auslagerung.](images/setup-05-layout.png)

Hier wird die Passphrase für die Datenträgerverschlüsselung gesetzt. Solange
sie fehlt, steht in der Zeile `-- not set --` und Setup geht nicht weiter.

![Nach dem Setzen der Passphrase ist der Bildschirm vollständig.](images/setup-05-layout-ready.png)

Die Auslagerung liegt standardmäßig auf **zram**, also komprimiert im
Arbeitsspeicher, und nicht auf dem Datenträger. Eine Auslagerungsdatei auf ZFS
ist keine Option — die Kombination führt zu Verklemmungen.

### 6 — Bestätigung

![Der letzte Bildschirm, bevor irgendetwas geschrieben wird.](images/setup-06-confirm.png)

Dies ist das Tor. Bis hierher wurde **nichts** auf den Datenträger
geschrieben. `F` bestätigt, `ESC` geht zurück. Geschrieben wird erst ab
Bildschirm 10 — die Bildschirme 7 bis 9 werden noch bei unangetastetem
Datenträger ausgefüllt.

### 7 — Computername und Administratorkonto

![Computername, Anmeldename, vollständiger Name und Kennwort.](images/setup-07-account-filled.png)

Das hier angelegte Konto ist das erste Administratorkonto der Maschine. Sein
Home-Verzeichnis bekommt ein eigenes ZFS-Dataset unterhalb von
`rpool/USERDATA` — außerhalb der Bootumgebung, damit ein späterer Rollback die
Dateien des Benutzers nicht mit zurücknimmt.

### 8 — Installationsart (nur amd64)

![Die Wahl zwischen Desktop und Headless.](images/setup-08-mode-desktop.png)

**GUI** installiert den klassischen OS/7-Desktop mit Microsoft Edge und dem
Intune-Portal. **Headless** installiert einen Server ohne Grafikstapel.

![Dieselbe Auswahl mit markiertem Headless-Eintrag.](images/setup-08-mode-headless.png)

Auf arm64 entfällt dieser Bildschirm, weil es dort nur Headless gibt.

### 9 — Netzwerk

![Adapter und Methode. Setup wendet die Einstellungen an und prüft sie, bevor sie ins installierte System geschrieben werden.](images/setup-09-network.png)

Setup zeigt die tatsächlich vorhandenen Adapter mit Typ, Treiber und
Verbindungszustand. Drei Methoden stehen zur Wahl: DHCP, feste Adresse, oder
gar keine Netzwerkkonfiguration.

Bemerkenswert ist die Zeile unten: **`F4` testet die Einstellung, bevor sie
übernommen wird.** Eine getippte statische Adresse, die nirgendwo hinführt,
fällt hier auf und nicht nach dem ersten Neustart.

Bei einer festen Adresse folgt Bildschirm **9S** mit Adresse, Präfixlänge,
Standardgateway, Namensservern und Suchdomänen; bei einem WLAN-Adapter
Bildschirm **9W** mit Netzwerkname und Authentifizierung.

### 10 und 11 — Kopieren und Einrichten

![Die Fortschrittsanzeige beim Schreiben auf den Datenträger.](images/setup-10-execute-1.png)

Ab hier arbeitet Setup: Partitionieren, LUKS anlegen, Pools erzeugen,
Datasets anlegen, das Dateisystem entpacken, das System konfigurieren, den
Bootloader installieren, das Konto anlegen und die TPM-Freischaltung
vorbereiten.

Jeder Schritt weist sich selbst nach — er stellt nicht fest, dass ein
Programm mit 0 zurückgekommen ist, sondern fragt das Ergebnis ab. Das
Protokoll dieser Nachweise landet auf der installierten Maschine unter
`/var/log/os7-setup/install.log` und ist später mit `Get-OS7InstallLog`
lesbar.

### 12 — Fertig

![Der Abschlussbildschirm nennt die vollständige Version der installierten Maschine.](images/setup-12-complete.png)

## 3.3 Unbeaufsichtigt installieren

Setup nimmt einen vollständigen Installationsplan als Datei entgegen und läuft
dann ohne Eingabe durch:

```
os7-setup --unattend /pfad/zu/plan.json
```

Der Plan ist JSON und enthält genau das, was die Bildschirme 3 bis 9
einsammeln:

```json
{
  "version": 1,
  "intent": "Install",
  "language": "de_DE.UTF-8",
  "keyboard": "de",
  "timezone": "Europe/Berlin",
  "mode": "Headless",
  "storage": {
    "disk": "/dev/disk/by-id/nvme-...",
    "layout": "single",
    "efiMiB": 512,
    "bpoolGiB": 2,
    "encrypt": true,
    "swap": "zram"
  },
  "account": {
    "hostname": "os7-srv-01",
    "username": "os7admin",
    "fullName": "OS/7 Administrator"
  },
  "network": {
    "interface": "auto",
    "kind": "Wired",
    "method": "Dhcp"
  }
}
```

Die Geheimnisse stehen **nicht** im Plan. Passphrase und Kennwort werden
getrennt übergeben, damit ein Plan gefahrlos in eine Bereitstellungsablage
gelegt werden kann.

Der vollständige Plan wird **einmal** geprüft, unmittelbar bevor der erste
Schreibvorgang beginnt. Das ist die einzige Stelle, an der „danach fängt
niemand mehr etwas ab" tatsächlich zutrifft.

## 3.4 Setup prüfen, bevor man ihm glaubt

Setup bringt einen Selbsttest mit:

```
os7-setup --self-test
```

Er prüft Palette, Schrift, Zeichenabdeckung und Tastendekodierung. Wenn an
einer Installation etwas seltsam aussieht, ist das der erste Befehl — er
läuft in Sekunden und braucht keinen Datenträger.

## 3.5 Nach der Installation

Beim ersten Start passiert zweierlei automatisch: die
**TPM2-Freischaltung** wird gegen die tatsächliche Startkette der installierten
Maschine eingerichtet, und die **Erstmigrationen** des Releases laufen durch.

Die TPM-Einrichtung gehört genau deshalb auf den ersten Start und nicht in den
Installer: Das Installationsmedium startet anders als die installierte
Maschine, und ein Schlüssel, der gegen den Zustand des Mediums versiegelt
wurde, öffnet sich auf der fertigen Maschine nicht. Sichtbar wird das Ergebnis
beim zweiten Start — er fragt nicht mehr nach der Passphrase.

Anschließend melden Sie sich an und prüfen die Maschine so, wie Kapitel 2.5 es
beschreibt.
