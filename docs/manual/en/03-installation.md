# 3 Installing a machine

Installation is done with **`os7-setup`**, OS/7's text-mode installer. It starts
from the installation medium by itself and needs no graphics card, no mouse and
no network.

## 3.1 What Setup lays down

Before you press a key it is worth knowing what ends up on the disk — because
this layout is the reason updates roll back later:

![The disk after installation. What matters is what lies inside and what lies outside the boot environment.](images/diagram-disk-en.svg)

Three partitions:

* an **EFI System Partition** (512 MB, FAT32) — unencrypted, because the
  firmware must be able to read it;
* a **boot pool** `bpool` (2 GB, ZFS) — unencrypted, because GRUB must be able
  to read it, and with a restricted feature set GRUB understands;
* the rest as a **LUKS2 container**, with the ZFS pool `rpool` inside it.

Encryption is **LUKS2 under ZFS**, not ZFS-native encryption. That is a
deliberate decision: LUKS is what Microsoft's management tooling on Linux
recognises and reports as disk encryption.

## 3.2 The screens, in order

### 1 — Welcome

![The first screen. The version sits at the top right of every screen.](images/setup-01-welcome.png)

`ENTER` installs, `R` repairs an existing installation, `F3` quits. `F5`
switches Setup to a higher-contrast field — for remote-management windows and
poor displays.

![The same screen with F5: a darker field, the same controls.](images/setup-01-welcome-high-contrast.png)

### 2 — Licence

![The licence terms, a page at a time with PAGE UP and PAGE DOWN.](images/setup-02-licence.png)

`F8` accepts, `ESC` declines.

### 3 — Regional settings

![Language, keyboard layout and time zone on one screen.](images/setup-03-regional.png)

What you choose here sets the language of the installed system, the console
keyboard layout and the time zone. The zone can be changed later with
`Set-OS7TimeZone`.

### 4 — Select a disk

![The machine's disks. The installation medium is listed and not selectable.](images/setup-04-disk.png)

Setup lists every disk and says what is on each. A disk that already carries an
OS/7 installation is recognised as such. The installation medium itself appears
in the list but is blocked — visible, so that nobody wonders where it went.

### 5 — Layout and encryption

![The layout at a glance, with encryption and swap.](images/setup-05-layout.png)

This is where the disk-encryption passphrase is set. Until it is, the line
reads `-- not set --` and Setup will not continue.

![Once the passphrase is set the screen is complete.](images/setup-05-layout-ready.png)

Swap defaults to **zram** — compressed, in memory — and not to the disk. A swap
file on ZFS is not an option; the combination deadlocks.

### 6 — Confirmation

![The last screen before anything is written.](images/setup-06-confirm.png)

This is the gate. Up to here **nothing** has been written to the disk. `F`
confirms, `ESC` goes back. Writing starts at screen 10 — screens 7 to 9 are
filled in while the disk is still untouched.

### 7 — Computer name and administrator account

![Computer name, login name, full name and password.](images/setup-07-account-filled.png)

The account created here is the machine's first administrator account. Its home
directory gets a ZFS dataset of its own under `rpool/USERDATA` — outside the
boot environment, so that a later rollback does not take the user's files with
it.

### 8 — Install mode (amd64 only)

![The choice between desktop and headless.](images/setup-08-mode-desktop.png)

**GUI** installs the classic OS/7 desktop with Microsoft Edge and the Intune
portal. **Headless** installs a server with no graphics stack.

![The same choice with the headless entry selected.](images/setup-08-mode-headless.png)

On arm64 this screen does not appear, because there is only headless.

### 9 — Network

![Adapter and method. Setup applies the settings and tests them before writing them to the installed system.](images/setup-09-network.png)

Setup shows the adapters that actually exist, with kind, driver and link state.
Three methods: DHCP, a static address, or no network configuration at all.

The line at the bottom is the notable one: **`F4` tests the setting before it is
committed.** A typed static address that leads nowhere shows up here rather
than after the first restart.

A static address leads to screen **9S** with address, prefix length, default
gateway, name servers and search domains; a wireless adapter leads to screen
**9W** with network name and authentication.

### 10 and 11 — Copying and configuring

![The progress display while the disk is written.](images/setup-10-execute-1.png)

From here Setup works: partition, create LUKS, create the pools, lay down the
datasets, unpack the filesystem, configure the system, install the bootloader,
create the account and prepare the TPM unlock.

Every step proves itself — it does not note that a program returned 0, it asks
for the result. The record of those proofs lands on the installed machine at
`/var/log/os7-setup/install.log` and is readable later with
`Get-OS7InstallLog`.

### 12 — Complete

![The Complete screen names the full version of the installed machine.](images/setup-12-complete.png)

## 3.3 Installing unattended

Setup takes a complete installation plan as a file and then runs without input:

```
os7-setup --unattend /path/to/plan.json
```

The plan is JSON and holds exactly what screens 3 to 9 collect:

```json
{
  "version": 1,
  "intent": "Install",
  "language": "en_GB.UTF-8",
  "keyboard": "gb",
  "timezone": "Europe/London",
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

The secrets are **not** in the plan. The passphrase and the password are passed
separately, so a plan can safely sit in a deployment share.

The whole plan is validated **once**, immediately before the first write. That
is the only place where "nothing downstream will catch this" is a true
sentence.

## 3.4 Checking Setup before trusting it

Setup carries a self-test:

```
os7-setup --self-test
```

It checks the palette, the font, glyph coverage and key decoding. When
something about an installation looks wrong, this is the first command — it
runs in seconds and needs no disk.

## 3.5 After installation

Two things happen automatically on the first boot: the **TPM2 unlock** is
enrolled against the installed machine's actual boot chain, and the release's
**first-boot migrations** run.

The TPM enrolment belongs on the first boot rather than in the installer for a
precise reason: the installation medium boots differently from the installed
machine, and a key sealed against the medium's state will not open on the
finished machine. The result is visible on the second boot — it no longer asks
for the passphrase.

After that, log in and check the machine the way chapter 2.5 describes.
