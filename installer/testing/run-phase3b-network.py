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
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vmconsole import Console, live_login, to_plain_bash, qemu_prefix    # noqa: E402
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
           "console=ttyAMA0,115200")
LIVE_CMDLINE = "boot=casper fbcon=nodefer quiet console=ttyAMA0,115200"

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
    pre = qemu_prefix()
    code = os.path.join(pre, "share", "qemu", "edk2-aarch64-code.fd")
    args = [
        "qemu-system-aarch64",
        "-machine", "virt,accel=hvf", "-cpu", "host",
        "-smp", lab.CPUS, "-m", lab.MEM,
        "-drive", f"if=pflash,format=raw,file={code},readonly=on",
        "-drive", f"if=pflash,format=raw,file={os.path.join(vmdir, 'edk2-vars.fd')}",
        "-display", "none", "-monitor", "none", "-serial", "stdio",
        "-drive", f"if=none,id=target,file={os.path.join(vmdir, 'target.qcow2')},format=qcow2",
        "-device", "virtio-blk-pci,drive=target,serial=os7target",
    ]
    if nic:
        args += ["-device", "virtio-net-pci,netdev=n0", "-netdev", "user,id=n0"]
    return args


def boot_installed(vmdir, label, passphrase, user, password):
    """Boot an installed disk alone and land on a shell. Returns the Console."""
    c = Console(disk_only_args(vmdir), os.path.join(vmdir, f"{label}.serial.log"))
    i = c.expect([r"unlock disk", r"Enter passphrase", r"passphrase for",
                  r"\(initramfs\)", r"Kernel panic", r"No bootable"],
                 600, "the passphrase prompt")
    if i >= 3:
        print(c.text()[-2000:])
        raise SystemExit("the machine never got as far as asking for the passphrase")
    c.send(passphrase)
    j = c.expect([r"\blogin:", r"\(initramfs\)", r"Kernel panic"], 900, "a login prompt")
    if j >= 1:
        print(c.text()[-2000:])
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
        c.send("poweroff")
        time.sleep(3)
    return True


# ---------------------------------------------------------------------------
def write_plan(c, iface):
    """A complete plan with a STATIC network, plus the secrets as separate files.

    THE INTERFACE NAME IS DISCOVERED, NOT ASSUMED. Predictable interface names
    come from the PCI topology, so what a virtio NIC is called on `machine virt`
    is a property of the QEMU version and the machine model rather than something
    this file can know. The first version wrote `enp0s1` and would have failed on
    any host where it is `ens1` — with a message about an address, which is the
    wrong thing to be told.

    It is still a NAME and not `auto`: this phase asserts an address on ONE
    interface, and a `match:` glob would make "which interface" part of what is
    being tested. run-phase3.py's unattended plan covers the `auto` path.
    """
    plan = ('{"version":1,"intent":"Install","language":"en_US.UTF-8",'
            '"keyboard":"us","timezone":"UTC","mode":"Headless",'
            f'"storage":{{"disk":"{TARGET}","layout":"single","efiMiB":512,'
            '"bpoolGiB":2,"encrypt":true,"swap":"zram"},'
            f'"account":{{"hostname":"{HOSTNAME}","username":"{USERNAME}",'
            '"fullName":"OS/7 Phase 3b"},'
            f'"network":{{"interface":"{iface}","kind":"Wired","method":"Static",'
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
        print(f"      the plan will name {iface}")

        write_plan(c, iface)
        c.drop()
        c.send("os7-setup --unattend /tmp/plan.json --passphrase-file /tmp/pass "
               "--password-file /tmp/pw")
        print("      installing … (unsquashfs + initramfs; ~15-25 min)")
        i = c.expect([r"OS7-SETUP-DONE install", r"OS7-SETUP-FAILED"], 2400, "the install")
        if i != 0:
            print(c.text()[-3000:])
            print("      FAIL  the install did not finish")
            return False
        print("      ok    the unattended install finished")

        # The netplan step's own output, on the serial line, before any reboot.
        text = c.text()
        for want, what in [
            ("Configuring the network", "the network step ran"),
            ("enabling systemd-networkd", "systemd-networkd was enabled"),
        ]:
            if want in text:
                print(f"      ok    {what}")
            else:
                print(f"      FAIL  {what}: '{want}' is not in the install output")
                return False
        return True
    finally:
        c.send("poweroff")
        time.sleep(3)


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
        out = ask(c, "grep renderer /etc/netplan/01-os7-network.yaml", "renderer")
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
    finally:
        c.send("poweroff")
        time.sleep(3)
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
        out = ask(c, "modprobe mac80211_hwsim radios=2 && echo LOADED", "hwsim", timeout=120)
        if "LOADED" not in out:
            print("      SKIP  mac80211_hwsim is not available in this kernel")
            print("            Wi-Fi association is therefore UNMEASURED on this run.")
            return True
        print("      ok    mac80211_hwsim loaded, two virtual radios")

        out = ask(c, "ls /sys/class/net | grep -c wlan", "wlan count", timeout=60)
        print(f"      wlan interfaces: {out.strip().splitlines()[-2:]}")

        for want, what in [("wpa_supplicant", "wpasupplicant is on the image"),
                           ("iw", "iw is on the image")]:
            out = ask(c, f"command -v {want} || echo MISSING", what, timeout=60)
            if "MISSING" in out:
                print(f"      FAIL  {what}: not found. The package list did not take.")
                return False
            print(f"      ok    {what}")

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
        ask(c, "rfkill unblock wifi; ip link set wlan1 up", "wlan1 up", timeout=60)
        ask(c, "wpa_supplicant -B -i wlan1 -c /tmp/ap.conf -D nl80211", "start ap", timeout=90)
        time.sleep(5)
        ask(c, f"ip addr add {AP_ADDRESS} dev wlan1", "ap address", timeout=60)
        out = ask(c, "iw dev wlan1 info", "ap info", timeout=60)
        if "type AP" not in out:
            print("      FAIL  wlan1 did not come up as an access point")
            print(out[-1200:])
            return False
        print(f"      ok    wlan1 is an access point broadcasting '{AP_SSID}'")

        # -- Setup's own scan, on wlan0 ---------------------------------------
        #
        # `iw scan` FIRST, so that a failure to see the AP is separated from a
        # failure to join it. Two different bugs; one message each.
        ask(c, "ip link set wlan0 up", "wlan0 up", timeout=60)
        time.sleep(3)
        out = ask(c, "iw dev wlan0 scan | grep -E 'SSID|signal'", "scan", timeout=120)
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
        c.send("os7-setup --test-network /tmp/wifi.json --wifi-secret-file /tmp/psk")
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
        out = ask(c, "iw dev wlan0 link; ip -o addr show wlan0", "link", timeout=90)
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
        c.send("poweroff")
        time.sleep(3)


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
