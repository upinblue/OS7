#!/usr/bin/env python3
"""
Phase 3b — the network screen, checked by asking a computer.

SETUP-PLAN Phase 3b's deliverable is one sentence: *a machine installed by Setup
boots into OS/7 and is reachable over the network the operator configured.* Every
target below ends by asking a machine what addresses it has, because that is the
only kind of evidence that distinguishes a configured network from a config file.

    ./run-phase3b-network.py m1        M1 - does a PRE-3b installed machine have
                                       a network at all?  (L23's measurement)
    ./run-phase3b-network.py install   install unattended with a STATIC address
    ./run-phase3b-network.py boot      BOOT THE DISK ALONE and ask `ip -o addr`
    ./run-phase3b-network.py wifi      associate over a simulated radio (PSK)
    ./run-phase3b-network.py all       install, boot, wifi   (default)
    ./run-phase3b-network.py reset     discard the VM state

WHY A STATIC ADDRESS AND NOT DHCP. `run-phase3.py` already walks the DHCP path
end to end - screen 9, F4, a real lease on the live medium, and the installed
machine coming up on 10.0.2.15. Repeating it here would add a second copy of the
same evidence. The static path is the one nothing else covers, and it is the
stronger assertion besides: the address on the installed machine is a value a
person typed, so it cannot have arrived from anywhere else. A DHCP lease could
in principle come from a network Setup never configured.

M1 IS DELIBERATELY A DIFFERENT SHAPE from the rest. It boots a disk installed by
a build from BEFORE this phase and reports what it finds, without asserting
anything. It exists to turn "the squashfs contains no network configuration"
into a statement about a running computer - or to overturn it. A measurement that
can only confirm is not a measurement.
"""

import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vmconsole import Console, live_login, to_plain_bash                # noqa: E402
from vmscreen import Lab                                                # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

PASSPHRASE = "os7-phase3b-passphrase"
PASSWORD = "os7-phase3b-password"
HOSTNAME = "os7-net"
USERNAME = "os7admin"

# The static address this phase types, and the one it then demands back out of a
# booted machine. In QEMU's user-mode network the gateway is always 10.0.2.2 and
# the DNS server 10.0.2.3, so .99 is free and every value here is known before
# the VM starts.
ADDRESS = "10.0.2.99/24"
GATEWAY = "10.0.2.2"
NAMESERVER = "10.0.2.3"

# The simulated radio. mac80211_hwsim gives the guest two virtual PHYs; one runs
# wpa_supplicant in AP mode (mode=2), the other is what Setup associates from.
# NO hostapd IS NEEDED for WPA2-PSK, which is why this test can exist at all
# without adding a package to the product. 802.1X WOULD need hostapd's EAP
# server, and is therefore NOT tested here - SETUP-PLAN Phase 3b says so, and
# D13 records that the line is deliberate.
AP_SSID = "OS7-TEST-AP"
AP_PSK = "os7testpassphrase"
AP_ADDRESS = "10.99.0.1/24"
WIFI_ADDRESS = "10.99.0.5/24"

lab = Lab("phase3b", target_gb=24, iso_as_disk=True, nic=True)

CMDLINE = ("boot=casper os7.setup=1 systemd.wants=os7-setup.service systemd.unit=multi-user.target "
           "fbcon=font:TER16x32 fbcon=nodefer plymouth.enable=0 quiet loglevel=0 "
           f"console={lab.arch.serial_tty},115200")
LIVE_CMDLINE = f"boot=casper fbcon=nodefer quiet console={lab.arch.serial_tty},115200"

TARGET = "/dev/disk/by-id/virtio-os7target"

_mark = 0


def ask(c, command, label, timeout=180):
    """Run something in the guest and return everything it printed.

    THE MARKER IS BUILT BY THE SHELL, NOT TYPED (BUILD-NOTES #16). `…; echo DONE`
    then waiting for "DONE" matches the shell's ECHO of the command being typed,
    so `expect` returns before the command has run.
    """
    global _mark
    _mark += 1
    n = _mark
    c.drop()
    c.send(f"{command}; printf 'OK%s\\n' {n}")
    c.expect(f"OK{n}", timeout, label)
    return c.text()


def ask_number(c, expr, label, timeout=120):
    """Ask the guest for ONE number and read the ANSWER, not the echo of the question.

    BUILD-NOTES #16, the half `ask` does not cover. `ask` returns everything the
    console showed, which includes the shell ECHOING the command as it was typed,
    and `ask`'s own marker is `OK<n>` with n counting up. So "the first bare
    integer in the text" finds the marker number, in the typed line, before it
    ever reaches the output — and it does it silently, returning a plausible
    small number.

    That is not hypothetical. On 2026-08-25 this returned 8, 10 and 11 for three
    counts whose real values were 15, 2 and 0, and every one of those was the
    value of `_mark` at the time. The assertion that used them reported a leak
    in a file that had none.

    The fix is the same shape as `ask`'s: the shell BUILDS the label. `printf
    'N=%s\n'` types the four characters `N=%s`, so a search for `N=` followed by
    DIGITS cannot match the echo — only the line printf produced.
    """
    out = ask(c, f"printf 'N=%s\\n' $({expr})", label, timeout)
    m = re.search(r"N=(\d+)", out)
    return int(m.group(1)) if m else -1


def shut_down(c, q=None):
    """Stop the VM, and MAKE SURE IT IS STOPPED.

    `poweroff` asks the guest; it does not guarantee the qemu process leaves,
    and a guest that never reaches the request - a failed phase, a hung boot -
    leaves it running forever. Three of these leaked in one afternoon on
    2026-08-25 and the symptom was not a slow Mac: the next run could not open
    its own disk image, because qemu holds a WRITE LOCK on it.

        qemu-system-aarch64: Failed to get "write" lock
        Is another process using the image ...?

    That is a message about the right thing pointing at the wrong run. And it is
    the same shape a previous session hit at 13h50m of leaked runtime, so it is
    a repeat rather than a surprise.

    Console.close() terminates and then kills. It is called from a finally in
    every phase, whether the phase passed, failed or threw.
    """
    try:
        c.send("poweroff")
        time.sleep(3)
    except Exception:
        pass
    if q is not None:
        try:
            q.close()
        except Exception:
            pass
    try:
        c.close()
    except Exception:
        pass


def disk_only_args(vmdir, nic=True):
    """QEMU with THE TARGET DISK AND NOTHING ELSE, plus a NIC.

    The same split run-phase3.py makes and for the same reason: no `-kernel`, no
    ISO, and the firmware variable store the install ran with. A VM that still
    has the setup medium attached can boot from the medium and look exactly like
    a successful install.

    The NIC is the point here. It is user-mode networking, so the guest sees a
    working segment whatever the host is doing - which matters because the
    assertion is about what the GUEST configured, not about whether this Mac has
    a network.
    """
    # `vmdir` is not always the lab's own state — phase m1 boots a hand-cloned
    # copy under .vm/m1 — so it is registered as a mount of its own.
    lab.arch.mount(vmdir)
    p = lab.arch.path
    args = lab.arch.base_args() + [
        "-smp", lab.CPUS, "-m", lab.MEM,
    ] + lab.arch.firmware_args(os.path.join(vmdir, "edk2-vars.fd")) + [
        "-display", "none", "-monitor", "none", "-serial", "stdio",
        "-drive", f"if=none,id=target,file={p(os.path.join(vmdir, 'target.qcow2'))},format=qcow2",
        "-device", "virtio-blk-pci,drive=target,serial=os7target",
    ]
    if nic:
        args += ["-device", "virtio-net-pci,netdev=n0", "-netdev", "user,id=n0"]
    return args


def boot_installed(vmdir, label, passphrase, user, password):
    """Boot an installed disk alone and land on a shell. Returns the Console."""
    c = Console(lab.arch.command(disk_only_args(vmdir), name=lab.name),
                os.path.join(vmdir, f"{label}.serial.log"))
    i = c.expect([r"unlock disk", r"Enter passphrase", r"passphrase for",
                  r"\(initramfs\)", r"Kernel panic", r"No bootable"],
                 600, "the passphrase prompt")
    # CLOSE BEFORE RAISING. A failure here is exactly when the VM is left
    # running, because nothing downstream gets a chance to tidy up - and the
    # next run then cannot open its own disk image, qemu holding the write lock.
    if i >= 3:
        print(c.text()[-2000:])
        c.close()
        raise SystemExit("the machine never got as far as asking for the passphrase")
    c.send(passphrase)
    j = c.expect([r"\blogin:", r"\(initramfs\)", r"Kernel panic"], 900, "a login prompt")
    if j >= 1:
        print(c.text()[-2000:])
        c.close()
        raise SystemExit("unlocked, but never reached a login prompt")
    live_login(c, user=user, password=password)
    to_plain_bash(c)
    return c


# ---------------------------------------------------------------------------
def phase_m1():
    """M1 — ask a PRE-Phase-3b installed machine whether it has a network.

    REPORTS, DOES NOT ASSERT. The claim it exists to settle is L23's: that the
    shipped image configures no network, so an installed arm64 machine comes up
    unreachable. That claim was derived from a squashfs, and a claim derived from
    a squashfs is a prediction about a computer, not a fact about one.

    The disk must be one an OLDER build installed. Clone it from another lab:

        cp -c .vm/phase3/target.qcow2 .vm/m1/target.qcow2
        cp    .vm/phase3/edk2-vars.fd .vm/m1/edk2-vars.fd
    """
    print("\n  M1 — what does an installed machine's network look like?")
    vmdir = os.path.join(REPO, ".vm", "m1")
    for need in ("target.qcow2", "edk2-vars.fd"):
        if not os.path.exists(os.path.join(vmdir, need)):
            print(f"      SKIP  no {need} in {vmdir}.")
            print("            Clone an installed disk there first — see the docstring.")
            return True

    # The account on a phase3 disk, not this phase's.
    c = boot_installed(vmdir, "m1", "os7-phase3-passphrase",
                       "os7admin", "os7-phase3-password")
    try:
        print("\n" + "  " + "-" * 68)
        for cmd, label in [
            ("ip -o link show", "interfaces the kernel has"),
            ("ip -o addr show", "addresses"),
            ("ip route show", "routes"),
            ("systemctl is-enabled systemd-networkd", "systemd-networkd enabled?"),
            ("systemctl is-active  systemd-networkd", "systemd-networkd active?"),
            ("systemctl is-enabled networkd-dispatcher", "networkd-dispatcher enabled?"),
            ("ls -A /etc/netplan/ || echo EMPTY", "/etc/netplan"),
            ("ls -A /run/systemd/network/ 2>/dev/null || echo EMPTY", "/run/systemd/network"),
            ("dpkg -l network-manager 2>/dev/null | tail -1 || echo ABSENT", "NetworkManager"),
        ]:
            out = ask(c, cmd, label, timeout=90)
            body = [l.rstrip() for l in out.splitlines()
                    if l.strip() and not l.startswith("OK") and cmd not in l]
            print(f"\n      {label}   ({cmd})")
            for line in body[:12]:
                print(f"          {line}")
        print("\n" + "  " + "-" * 68)
        print("      M1 is a REPORT. Read it against L23 and record the answer in")
        print("      docs/SESSION-NETWORK-ACCOUNTS-PLAN.md — it is not a pass/fail.")
    finally:
        shut_down(c)
    return True


# ---------------------------------------------------------------------------
def write_plan(c, iface, mac):
    """A complete plan with a STATIC network, plus the secrets as separate files.

    THE INTERFACE NAME IS DISCOVERED, NOT ASSUMED. Predictable interface names
    come from the PCI topology, so what a virtio NIC is called on `machine virt`
    is a property of the QEMU version and the machine model rather than something
    this file can know. The first version wrote `enp0s1` and would have failed on
    any host where it is `ens1` — with a message about an address, which is the
    wrong thing to be told.

    AND THE MAC GOES IN WITH IT, because the name is not stable across the
    install either: the setup medium is a PCI device and removing it renumbers
    the slots predictable names come from. Measured here on 2026-08-25 - enp0s5
    while installing, enp0s2 once booted, one machine and one NIC. netplan
    matches on the MAC; the name is what the operator saw and what the log says.
    """
    plan = ('{"version":1,"intent":"Install","language":"en_US.UTF-8",'
            '"keyboard":"us","timezone":"UTC","mode":"Headless",'
            f'"storage":{{"disk":"{TARGET}","layout":"single","efiMiB":512,'
            '"bpoolGiB":2,"encrypt":true,"swap":"zram"},'
            f'"account":{{"hostname":"{HOSTNAME}","username":"{USERNAME}",'
            '"fullName":"OS/7 Phase 3b"},'
            f'"network":{{"interface":"{iface}","macAddress":"{mac}",'
            f'"kind":"Wired","method":"Static",'
            f'"address":"{ADDRESS}","gateway":"{GATEWAY}",'
            f'"nameservers":["{NAMESERVER}"],"search":["os7.test"]}}}}')
    c.drop()
    c.send(f"printf '%s' '{plan}' > /tmp/plan.json")
    c.send(f"printf '%s' '{PASSPHRASE}' > /tmp/pass")
    c.send(f"printf '%s' '{PASSWORD}' > /tmp/pw")
    ask(c, "wc -c /tmp/plan.json /tmp/pass /tmp/pw", "plan files")


def phase_install():
    print("\n  install — unattended, with a static address")

    # The same precondition run-phase3.py's walk makes, and for the same reason:
    # a lab with no NIC would install a plan whose netplan file matches no
    # interface, which netplan accepts. Every later assertion in this file would
    # then fail with a message about an address, pointing at the wrong thing.
    if not lab.nic:
        print("      FAIL  this lab has no NIC. Lab(nic=True).")
        return False

    lab.prepare()
    c, q = lab.boot(LIVE_CMDLINE, "install")
    try:
        # WHICH INTERFACE THE GUEST ACTUALLY HAS, asked rather than assumed. The
        # plan above names enp0s1, and if this VM calls it something else the
        # install would write a netplan file matching nothing - which netplan
        # accepts and which produces a machine with no network. Better to fail
        # here, in one line, than to debug it after a boot.
        # WHICH INTERFACE THE GUEST ACTUALLY HAS, asked rather than assumed.
        # Predictable names come from the PCI topology, so a virtio NIC on
        # `machine virt` may be enp0s1 or ens1 depending on the QEMU version.
        # A plan naming the wrong one produces a netplan file matching nothing,
        # which netplan ACCEPTS - and the machine comes up with no network and
        # no error anywhere.
        out = ask(c, "ls /sys/class/net", "interface names")
        names = [n for n in out.split()
                 if n != "lo" and not n.startswith("OK") and "/" not in n]
        wired = [n for n in names if n.startswith(("en", "eth"))]
        print(f"      interfaces on the live medium: {' '.join(names)}")
        if not wired:
            print("      FAIL  this VM has no wired interface; the NIC did not attach")
            return False
        iface = wired[0]
        out = ask(c, f"cat /sys/class/net/{iface}/address", "mac")
        mac = ""
        for line in out.splitlines():
            t = line.strip()
            if len(t) == 17 and t.count(":") == 5:
                mac = t
                break
        if not mac:
            print(f"      FAIL  could not read a MAC for {iface}")
            return False
        print(f"      the plan will name {iface} and match on {mac}")

        write_plan(c, iface, mac)
        c.drop()
        # `sudo`, because casper logs in as an unprivileged user and Setup opens
        # block devices. Without it the run dies at the first sgdisk with
        # "Error is 13 ... You must run this program as root", which is a
        # perfectly clear message about the wrong thing: the harness, not the
        # installer.
        c.send("sudo os7-setup --unattend /tmp/plan.json --passphrase-file /tmp/pass "
               "--password-file /tmp/pw")
        print("      installing … (unsquashfs + initramfs; ~15-25 min)")
        i = c.expect([r"OS7-SETUP-DONE install", r"OS7-SETUP-FAILED"], 2400, "the install")
        if i != 0:
            print(c.text()[-3000:])
            print("      FAIL  the install did not finish")
            return False
        print("      ok    the unattended install finished")

        # WHAT THE CONSOLE CAN ACTUALLY CARRY, and no more.
        #
        # The first version of this also demanded "enabling systemd-networkd",
        # which the chroot script prints. It never appeared, and the reason was
        # not the installer: `Executor.Exec` captures a subprocess's stdout with
        # ReadToEnd and never writes it out, so no chroot script's output reaches
        # the serial line at all. The assertion watched for something the console
        # structurally could not carry, and reported the installer for it.
        #
        # The progress lines DO reach it, so that is what is checked here. The
        # real evidence - that networkd is enabled and running, that the netplan
        # file says networkd, that the address is the typed one - is asserted in
        # `boot`, against the installed machine, where it belongs.
        text = c.text()
        if "Configuring the network" not in text:
            print("      FAIL  the network step never ran")
            return False
        print("      ok    the network step ran")
        print("      note  the step's own proofs are in /var/log/os7-setup/install.log")
        print("            ON THE TARGET - the live medium's copy goes with the")
        print("            reboot (L31); `boot` reads the surviving one")
        return True
    finally:
        shut_down(c, q)


def phase_boot():
    """THE DELIVERABLE. No ISO — the disk boots, and the address is the typed one."""
    print("\n  boot — the installed disk alone, asked what address it has")
    for need in (lab.target, lab.vars):
        if not os.path.exists(need):
            print(f"      FAIL  nothing installed at {need}. Run `install` first.")
            return False

    c = boot_installed(lab.dir, "boot", PASSPHRASE, USERNAME, PASSWORD)
    ok = True
    try:
        print("      ok    the machine booted from the disk alone")

        want = ADDRESS.split("/")[0]

        # 1 — THE ADDRESS, FROM THE KERNEL. Not from netplan, not from a config
        # file, and not from an exit code: `ip` reports what the interface has.
        out = ask(c, "ip -o addr show", "addresses", timeout=120)
        if want in out:
            print(f"      ok    the interface has {ADDRESS} — the address that was typed")
        else:
            ok = False
            print(f"      FAIL  {want} is not on any interface")
            for line in out.splitlines()[:15]:
                if line.strip():
                    print(f"            {line.rstrip()}")
            # NAME THE LIKELY CAUSE. A netplan file that matches no interface
            # produces exactly this - no address, no route, no error - and the
            # interface name is the thing most likely to differ between the
            # install environment and the installed machine, because the setup
            # medium occupies a PCI slot and predictable names come from the PCI
            # topology. Printing the links and what netplan generated turns
            # "no address" into a diagnosis.
            for cmd, label in [("ip -o link show", "the links this machine has"),
                               (f"echo {PASSWORD} | sudo -S cat /etc/netplan/01-os7-network.yaml 2>/dev/null",
                                "the netplan file on the disk"),
                               ("ls -A /run/systemd/network/ 2>/dev/null || echo NONE",
                                "what netplan generated")]:
                extra = ask(c, cmd, label, timeout=90)
                print(f"            --- {label} ---")
                for line in extra.splitlines()[:12]:
                    if line.strip() and not line.startswith("OK") and cmd not in line:
                        print(f"            {line.rstrip()}")

        # 2 — THE ROUTE. An address with no default route is a machine that can
        # talk to its own segment and nothing else, which is a different failure
        # and one an address check alone would call success.
        out = ask(c, "ip route show default", "default route", timeout=60)
        if GATEWAY in out:
            print(f"      ok    the default route goes via {GATEWAY}")
        else:
            ok = False
            print(f"      FAIL  no default route via {GATEWAY}")

        # 3 — networkd is RUNNING, not merely enabled. L23 is precisely the gap
        # between those two words: on the shipped image networkd-dispatcher was
        # enabled and networkd was not, and the enabled-units list read like
        # evidence that networking was configured.
        out = ask(c, "systemctl is-active systemd-networkd", "networkd active", timeout=60)
        if "active" in out and "inactive" not in out:
            print("      ok    systemd-networkd is running")
        else:
            ok = False
            print("      FAIL  systemd-networkd is not running on the installed machine")

        # 4 — THE FILE ON THE DISK, and its mode. L25: the netplan file may hold
        # a Wi-Fi passphrase in plaintext, so 0600 is the whole mitigation and it
        # is checked on the installed system rather than on a dry run.
        out = ask(c, "stat -c '%a %n' /etc/netplan/01-os7-network.yaml", "netplan mode")
        if "600 /etc/netplan/01-os7-network.yaml" in out:
            print("      ok    /etc/netplan/01-os7-network.yaml is mode 0600 (L25)")
        else:
            ok = False
            print("      FAIL  the netplan file is not 0600")
            print(f"            {out.strip()[:200]}")

        # 5 — THE RENDERER, on the disk. D14: a headless install must render to
        # networkd, because the desktop purge removed NetworkManager. This is the
        # assertion L24 exists for, made against the installed machine.
        # `sudo`: the file is 0600 and owned by root, which is L25 working.
        out = ask(c, f"echo {PASSWORD} | sudo -S grep renderer "
                     "/etc/netplan/01-os7-network.yaml 2>/dev/null", "renderer")
        if "networkd" in out:
            print("      ok    the renderer on the disk is networkd (headless, D14)")
        else:
            ok = False
            print("      FAIL  the netplan file does not name networkd")
            print(f"            {out.strip()[:200]}")

        # 6 — DNS. systemd-resolved serves a stub, and a resolv.conf that does
        # not point at it resolves nothing while looking perfectly configured.
        out = ask(c, "readlink -f /etc/resolv.conf; resolvectl status 2>/dev/null | head -20",
                  "dns", timeout=90)
        if "stub-resolv.conf" in out or NAMESERVER in out:
            print("      ok    /etc/resolv.conf points at the resolved stub")
        else:
            ok = False
            print("      FAIL  /etc/resolv.conf does not point at systemd-resolved")
            print(f"            {out.strip()[:300]}")

        # 7 — THE INSTALL LOG SURVIVED THE RESTART (L31). Setup writes its log
        # to /var/log/os7-setup/setup.log on the LIVE system, which is casper's
        # RAM overlay, so until 2026-08-25 the entire record of the install —
        # every step's self-proof — was discarded by the reboot screen 12 offers,
        # and screen 12 printed the live path on the way out. InstallLogStep
        # copies the log onto the target before the pools are exported.
        #
        # ASKED OF A MACHINE THAT HAS NO ISO ATTACHED, which is the only place
        # the question means anything: this VM cannot see the live filesystem, so
        # a file here came off the disk.
        #
        # EVERY NUMBER BELOW GOES THROUGH ask_number. The first version of this
        # block parsed "the first integer in the console text" and read the
        # harness's own OK-marker out of the echoed command line every time.
        L = "/var/log/os7-setup/install.log"
        sudo = f"echo {PASSWORD} | sudo -S"

        mode = ask_number(c, f"{sudo} stat -c %a {L} 2>/dev/null || echo 0", "the log's mode")
        size = ask_number(c, f"{sudo} stat -c %s {L} 2>/dev/null || echo 0", "the log's size")
        if mode == 600 and size > 0:
            print(f"      ok    {L} is on the disk, mode 0600 ({size} bytes)")
        else:
            ok = False
            print(f"      FAIL  the install log is not on the installed disk (L31) — "
                  f"mode {mode}, {size} bytes")

        # ...AND IT HAS THE PROOFS IN IT, not just a header. The chroot scripts
        # are where the steps check their own work — AccountStep reads the hash
        # length back out of /etc/shadow, NetworkStep reads back the unit netplan
        # generated — and those lines are the reason this file is worth keeping.
        # A file that exists and holds nothing is the likelier failure.
        steps = ask_number(c, f"{sudo} grep -c 'step: ' {L} 2>/dev/null || echo 0", "steps")
        proof = ask_number(c, f"{sudo} grep -c -- '-character hash' {L} 2>/dev/null || echo 0",
                           "the account proof")
        if steps >= 12 and proof >= 1:
            print(f"      ok    it holds {steps} step lines and AccountStep's /etc/shadow proof")
        else:
            ok = False
            print(f"      FAIL  the install log holds {steps} step lines and {proof} "
                  "account proofs — the record did not reach the disk")

        # AND IT IS THE WHOLE LOG, not its tail. The log was a 200-entry ring
        # until 2026-08-25 and a dry run alone writes 284 lines, so a copy made
        # from it arrived complete-looking with the storage phase already dropped
        # off the front. `step: Generating the host identifier` is the FIRST step
        # of the install; if it is here, nothing fell off in front of it.
        first = ask_number(c, f"{sudo} grep -c 'Generating the host identifier' {L} "
                              "2>/dev/null || echo 0", "the first step")
        if first >= 1:
            print("      ok    the first step of the install is in it — not a tail")
        else:
            ok = False
            print("      FAIL  the record starts after the first step; it is a tail, not a log")

        # THE REDACTION, ON A REAL DISK. `passphrase set (N characters)` is marked
        # Log.LiveOnly: true, useful while Setup is running, and a narrowing of
        # the search space once it sits in /var/log of a machine whose first
        # account is in sudo. The persistent copy carries "[not kept]" instead.
        # BOTH WAYS, because a redactor that empties the file passes the first
        # half on its own — and the proofs check above is the second half.
        #
        # `characters)` with the bracket: that is the SHAPE of the lines
        # Log.LiveOnly marks — "(26 characters)" — and it does not match the one
        # other place the word appears, a chroot script's failure message.
        #
        # ANCHORED AT THE END OF THE LINE. A redacted entry IS "<prefix> [not
        # kept]"; the transcript's header explains the marker and so contains the
        # words too. Unanchored, this counts the header as a redaction — it would
        # go green on a redactor that had stopped marking anything.
        redacted = ask_number(c, f"{sudo} grep -c '\\[not kept\\]$' {L} 2>/dev/null || echo 0",
                              "redacted lines")
        leaked = ask_number(c, f"{sudo} grep -c 'characters)' {L} 2>/dev/null || echo 0",
                            "leaked lengths")
        if redacted >= 1 and leaked == 0:
            print(f"      ok    {redacted} line(s) about a secret are redacted, none leaked (L31)")
        else:
            ok = False
            print(f"      FAIL  {redacted} redaction marker(s), {leaked} line(s) still "
                  "naming a secret's length")

        # THE NEGATIVE CONTROL. The live log's path must NOT be here. If it were,
        # everything above could be passing on a file that arrived some other way
        # — and the claim being made is precisely that the live one is gone. It
        # is also the check that catches the build putting one in the image:
        # `--self-test` runs in the chroot during the ISO build, and until
        # `Log.MemoryOnly` it opened the log file there.
        #
        # Through ask_number too, and for the reason the first version of this
        # line got wrong: `test -e X && echo PRESENT || echo ABSENT` types BOTH
        # words, so `"ABSENT" in out` matches the echo of the question whatever
        # the answer was. Only `test`'s exit status is built by the shell.
        live = ask_number(c, "test -e /var/log/os7-setup/setup.log; echo $?",
                          "the live log's path")
        if live == 1:
            print("      ok    the live log's own path is absent — the copy is the copy")
        else:
            ok = False
            print("      FAIL  /var/log/os7-setup/setup.log exists on the installed disk; "
                  "the assertions above prove nothing")
    finally:
        shut_down(c)
    return ok


# ---------------------------------------------------------------------------
def phase_wifi():
    """Associate over a SIMULATED RADIO, and get the typed address on it.

    mac80211_hwsim gives the guest two virtual PHYs. One runs wpa_supplicant in
    AP mode — `mode=2`, which wpa_supplicant supports for WPA2-PSK — and the
    other is what Setup associates from. That is why this test needs nothing
    added to the product: the AP is the same wpasupplicant screen 9W already
    needs.

    802.1X IS NOT TESTED HERE and that is written down rather than left as a
    silence. PEAP/MSCHAPv2 needs an EAP server, `hostapd` is the one that has
    one, and it is not on the image. D13 puts 802.1X in v1 on the strength of
    generated configuration and a screen walk; SETUP-PLAN Phase 3b says the same,
    and until somebody runs it against real RADIUS on real hardware that is what
    it is worth.

    The address is STATIC on purpose: an AP made of wpa_supplicant serves no
    DHCP, and adding a DHCP server would mean adding a package. What this proves
    is the association, which is the part that can fail on a passphrase.
    """
    print("\n  wifi — a simulated radio, a real association (WPA2-PSK)")
    lab.prepare()
    c, q = lab.boot(LIVE_CMDLINE, "wifi")
    ok = True
    try:
        # THROUGH ask_number, ALL OF IT, and not as tidying. The two checks that
        # used to be here both matched a word the TYPED COMMAND contained, so
        # neither ever asked the guest anything:
        #
        #   modprobe … && echo LOADED   ->  "LOADED" not in out   ALWAYS FALSE
        #   command -v X || echo MISSING ->  "MISSING" in out      ALWAYS TRUE
        #
        # One was a green line that meant nothing and one was a red line that
        # meant nothing, from the same mistake, and the green one is the worse
        # of the two. BUILD-NOTES #16; see ask_number.
        ask(c, "sudo modprobe mac80211_hwsim radios=2", "hwsim", timeout=120)

        # AND THE RADIOS ARE COUNTED, rather than modprobe's exit code trusted.
        # "two virtual radios" is a claim about /sys/class/net, so that is what
        # is asked - the module loading is a diagnostic, the interfaces are the
        # thing itself.
        radios = ask_number(c, "ls /sys/class/net | grep -c wlan", "wlan count", timeout=60)
        if radios < 2:
            print(f"      SKIP  mac80211_hwsim gave {radios} radio(s), not 2")
            print("            Wi-Fi association is therefore UNMEASURED on this run.")
            return True
        print(f"      ok    mac80211_hwsim loaded, {radios} virtual radios")

        out = ask(c, "ls /sys/class/net | tr '\\n' ' '", "wlan names", timeout=60)
        wlans = [w for w in out.split() if w.startswith("wlan")]
        print(f"      wlan interfaces: {' '.join(wlans) if wlans else '(none)'}")
        if len(wlans) < 2:
            print("      FAIL  mac80211_hwsim did not produce two radios")
            return False

        # THE FILE, NOT `command -v`. The first version used `command -v
        # wpa_supplicant`, which failed - and the package IS on the image
        # (wpasupplicant 2:2.11 is in the manifest). casper logs in
        # unprivileged, and /usr/sbin is not on an unprivileged PATH, so
        # `command -v` was answering "is it on YOUR path" while the message it
        # printed said "the package list did not take".
        #
        # A correct check answering a different question from the one asked,
        # which is the third time this phase has produced that shape. Testing
        # for the file says what is actually meant.
        #
        # BOTH /usr/sbin AND /sbin, and it is not belt-and-braces: measured
        # 2026-08-25, these land under /sbin in the shipped squashfs, and on a
        # usrmerge system the two names are the same file only for as long as
        # that stays true. The question is "is it in the image", so ask it of
        # every path the image could have used.
        for name, what in [("wpa_supplicant", "wpasupplicant is on the image"),
                           ("iw", "iw is on the image"),
                           ("rfkill", "rfkill is on the image")]:
            found = ""
            for path in (f"/usr/sbin/{name}", f"/sbin/{name}"):
                out = ask(c, f"test -x {path} && echo FOUND || echo MISSING {path}",
                          what, timeout=60)
                if "FOUND" in out:
                    found = path
                    break
            if not found:
                print(f"      FAIL  {what}: not at /usr/sbin/{name} or /sbin/{name}.")
                print("            The three-package addition to os7-base.list.chroot")
                print("            did not reach this image.")
                return False
            print(f"      ok    {what}  ({found})")

        # -- the access point, on wlan1 ---------------------------------------
        ap = (f'network={{\\n'
              f'  ssid="{AP_SSID}"\\n'
              f'  mode=2\\n'
              f'  frequency=2412\\n'
              f'  key_mgmt=WPA-PSK\\n'
              f'  proto=RSN\\n'
              f'  pairwise=CCMP\\n'
              f'  group=CCMP\\n'
              f'  psk="{AP_PSK}"\\n'
              f'}}\\n')
        c.drop()
        c.send(f"printf '{ap}' > /tmp/ap.conf")
        ask(c, "cat /tmp/ap.conf", "ap config")
        ask(c, "sudo /usr/sbin/rfkill unblock wifi; sudo ip link set wlan1 up", "wlan1 up",
            timeout=60)
        # `-dd -f`: wpa_supplicant DAEMONISES with -B, so anything it decides
        # after the fork - "AP mode not supported", a regulatory refusal, a
        # config key it ignored - goes nowhere at all. The first run of this got
        # "Successfully initialized wpa_supplicant" and an interface still in
        # `type managed`, which is a success message about the wrong thing.
        ask(c, "sudo /usr/sbin/wpa_supplicant -B -dd -f /tmp/wpa.log "
               "-i wlan1 -c /tmp/ap.conf -D nl80211", "start ap", timeout=90)

        # POLLED, NOT SLEPT - the same fix as the DHCP lease in run-phase3.py,
        # in the same file, five days' worth of the same mistake apart.
        #
        # This slept 5 seconds and then asserted `type AP`. Measured 2026-08-25:
        # `wpa_supplicant -B` returns 0 and says "Successfully initialized"
        # IMMEDIATELY, is still running five seconds later, and the interface is
        # STILL `type managed` at that point; a foreground run with -d reaches
        # `State: COMPLETED` before 12 seconds. So the AP was real and the phase
        # photographed it too early - and then reported "wlan1 did not come up as
        # an access point", which named a cause it did not have.
        #
        # How long it actually takes depends on how loaded this Mac is, and this
        # repository runs several sessions on one machine. 45 seconds.
        print("      bringing the access point up ... (polled, up to 45s)")
        got_ap = False
        out = ""
        for _ in range(15):
            time.sleep(3)
            out = ask(c, "sudo /usr/sbin/iw dev wlan1 info", "ap info", timeout=60)
            if "type AP" in out:
                got_ap = True
                break
            # STOP EARLY IF THE DAEMON IS GONE. Waiting 45 seconds for a process
            # that exited is 45 seconds spent proving nothing, and "it died" and
            # "it is slow" want different fixes. The pattern must not name the
            # flags: they moved once already, when -dd -f went in.
            if ask_number(c, "pgrep -cf 'wpa_supplicant.*wlan1' || echo 0",
                          "ap alive", timeout=60) < 1:
                print("      FAIL  the access point's wpa_supplicant exited")
                got_ap = False
                break
        if not got_ap:
            print("      FAIL  wlan1 did not come up as an access point within 45s")
            print("      --- what iw says ---")
            print(out[-800:])
            # ASK THE THING ITSELF. wpa_supplicant's own log is the only place
            # its reason exists, and -f above is what put one there.
            for cmd, label in [("sudo /usr/sbin/wpa_cli -i wlan1 status", "wpa_cli"),
                               ("sudo tail -40 /tmp/wpa.log", "wpa_supplicant log"),
                               ("dmesg | tail -20", "kernel")]:
                extra = ask(c, cmd, label, timeout=90)
                print(f"      --- {label} ---")
                for line in extra.splitlines()[:40]:
                    if line.strip() and not line.startswith("OK"):
                        print(f"          {line.rstrip()}")
            return False
        print(f"      ok    wlan1 is an access point broadcasting '{AP_SSID}'")

        # THE ADDRESS AFTER THE MODE, not before it. Switching iftype takes the
        # interface down and up again, so an address added first is an address
        # that may not be there afterwards.
        ask(c, f"sudo ip addr add {AP_ADDRESS} dev wlan1", "ap address", timeout=60)

        # -- Setup's own scan, on wlan0 ---------------------------------------
        #
        # `iw scan` FIRST, so that a failure to see the AP is separated from a
        # failure to join it. Two different bugs; one message each.
        ask(c, "sudo ip link set wlan0 up", "wlan0 up", timeout=60)
        time.sleep(3)
        out = ask(c, "sudo /usr/sbin/iw dev wlan0 scan | grep -E 'SSID|signal'", "scan", timeout=120)
        if AP_SSID not in out:
            print(f"      FAIL  wlan0 cannot see '{AP_SSID}'")
            print(out[-1200:])
            return False
        print(f"      ok    wlan0's scan finds '{AP_SSID}'")

        # -- os7-setup joins it -----------------------------------------------
        #
        # THROUGH `--test-network`, which is the same NetworkProbe.Test that
        # screen 9W's F4 calls. Driving the framebuffer here would prove the
        # screen; this proves the code the screen calls, which is the half that
        # talks to a radio.
        plan = ('{"version":1,"network":{"interface":"wlan0","kind":"Wireless",'
                f'"method":"Static","address":"{WIFI_ADDRESS}",'
                f'"wifi":{{"ssid":"{AP_SSID}","security":"Psk"}}}}}}')
        c.drop()
        c.send(f"printf '%s' '{plan}' > /tmp/wifi.json")
        c.send(f"printf '%s' '{AP_PSK}' > /tmp/psk")
        ask(c, "wc -c /tmp/wifi.json /tmp/psk", "wifi plan")

        c.drop()
        c.send("sudo os7-setup --test-network /tmp/wifi.json --wifi-secret-file /tmp/psk")
        i = c.expect([r"OS7-NETWORK OK", r"OS7-NETWORK FAILED"], 180, "the association")
        if i != 0:
            print("      FAIL  os7-setup could not join the network")
            print(c.text()[-2500:])
            ok = False
        else:
            print("      ok    os7-setup associated and configured wlan0")

        # AND THE KERNEL AGREES. `--test-network` already checks with `ip`, so
        # this is the check on the checker: if the two ever disagree, the one to
        # believe is this one.
        out = ask(c, "sudo /usr/sbin/iw dev wlan0 link; ip -o addr show wlan0", "link", timeout=90)
        if AP_SSID in out and WIFI_ADDRESS.split("/")[0] in out:
            print(f"      ok    wlan0 is associated to '{AP_SSID}' with {WIFI_ADDRESS}")
        else:
            ok = False
            print("      FAIL  wlan0 is not associated with the address that was asked for")
            for line in out.splitlines()[:12]:
                if line.strip():
                    print(f"            {line.rstrip()}")
        return ok
    finally:
        shut_down(c, q)


# ---------------------------------------------------------------------------
def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    print(f"\n### Phase 3b — the network ({what})")

    if what == "reset":
        if os.path.exists(lab.dir):
            shutil.rmtree(lab.dir)
            print(f"    removed {lab.dir}")
        return 0

    phases = {"m1": [phase_m1], "install": [phase_install], "boot": [phase_boot],
              "wifi": [phase_wifi],
              "all": [phase_install, phase_boot, phase_wifi]}
    if what not in phases:
        print(__doc__)
        return 2

    for phase in phases[what]:
        if not phase():
            print(f"\n  {phase.__name__} FAILED\n")
            return 1

    # `m1` ASSERTS NOTHING, so it must not be told it passed. Printing "every
    # check passed" after a phase that made no checks is the same wrong sentence
    # this file exists to stop: a run that could not fail reporting success.
    if what == "m1":
        print("\n  M1 produced a report. Nothing was asserted.\n")
    else:
        print("\n  Phase 3b: every check passed.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
