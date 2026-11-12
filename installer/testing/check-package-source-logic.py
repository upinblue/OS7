#!/usr/bin/env python3
"""
Vendor package sources (docs/VENDOR-APPS-PLAN.md VA2-VA8) against REAL apt.

    ./installer/testing/check-package-source-logic.py            ~2 min, docker
    ./installer/testing/check-package-source-logic.py --no-prove  the checks only

WHAT IS REAL AND WHAT IS NOT. apt, apt-cache, dpkg and gpg are the real ones,
in a ubuntu:26.04 container with the pinned PowerShell (the image
check-update-logic.py builds). The vendor repository is a real signed apt
repository this script builds — three packages, an InRelease signed by a test
key — served over HTTP from 127.0.0.1, so `Pin: origin 127.0.0.1` means what
it means on a machine. Nothing is faked, because the claims are about apt:
that a pin by origin confines a repository to the packages named, that a
mismatched key fails LOUDLY, that the timer upgrades named packages and never
runs a full-upgrade. A fake apt would only prove what the fake was told.

WHAT IT DOES NOT COVER: a boot environment, an update in a chroot, a machine.
Update-OS7's vendor steps (VA6) are check-update-logic.py's and a bench's.

TWO KEYS. A signs the repository and is the one admitted. B is the stranger:
admitted by mistake, mixed into the same keyring, or rotated in by the vendor.

AND THEN EVERY RULE IS PROVEN TO FIRE: seven planted defects, each in a COPY of
powershell/ inside the container, each required to turn a named scenario RED
(--no-prove skips them). A rule nobody has seen fail is a comment with an exit
code (BUILD-NOTES #189).
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
IMAGE = "os7-check-update:latest"
PORT = 8765
URI = f"http://127.0.0.1:{PORT}/vendor"
LAB = "/tmp/os7-vendorlab"


def sh(argv, **kw):
    return subprocess.run(argv, capture_output=True, text=True, encoding="utf-8",
                          errors="replace", **kw)


# ---------------------------------------------------------------------------
# The vendor repository
# ---------------------------------------------------------------------------
def gpg(home, *args, inp=None):
    return subprocess.run(["gpg", "--batch", "--homedir", home, "--pinentry-mode", "loopback",
                           "--passphrase", ""] + list(args),
                          input=inp, capture_output=True)


def make_key(name):
    home = os.path.join(LAB, "gnupg-" + name)
    os.makedirs(home, mode=0o700, exist_ok=True)
    r = gpg(home, "--quick-gen-key", f"VendorLab {name} <{name.lower()}@vendorlab.test>",
            "ed25519", "sign", "never")
    assert r.returncode == 0, r.stderr.decode()
    pub = gpg(home, "--export").stdout
    path = os.path.join(LAB, f"key-{name}.gpg")
    with open(path, "wb") as fh:
        fh.write(pub)
    out = gpg(home, "--with-colons", "--list-keys").stdout.decode()
    fpr = [l.split(":")[9] for l in out.splitlines() if l.startswith("fpr:")][0]
    return home, path, fpr


def build_deb(name, version, arch):
    d = tempfile.mkdtemp(dir=LAB)
    os.makedirs(os.path.join(d, "DEBIAN"))
    os.makedirs(os.path.join(d, "usr", "share", "doc", name))
    with open(os.path.join(d, "usr", "share", "doc", name, "VERSION"), "w") as fh:
        fh.write(version + "\n")
    with open(os.path.join(d, "DEBIAN", "control"), "w") as fh:
        fh.write(f"Package: {name}\nVersion: {version}\nArchitecture: {arch}\n"
                 f"Maintainer: VendorLab <lab@vendorlab.test>\nDescription: OS/7 vendor lab package\n")
    out = os.path.join(LAB, "debs", f"{name}_{version}_{arch}.deb")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    r = sh(["dpkg-deb", "--root-owner-group", "--build", d, out])
    assert r.returncode == 0, r.stderr
    shutil.rmtree(d)
    return out


def publish(signer_home, packages, arch):
    """Write the repository: pool, Packages per architecture, Release, InRelease."""
    root = os.path.join(LAB, "www", "vendor")
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(os.path.join(root, "pool"))
    by_arch = {arch: [], "all": []}
    for deb, name, version, a in packages:
        dst = os.path.join(root, "pool", os.path.basename(deb))
        shutil.copy(deb, dst)
        data = open(dst, "rb").read()
        by_arch[a].append(
            f"Package: {name}\nVersion: {version}\nArchitecture: {a}\n"
            f"Maintainer: VendorLab <lab@vendorlab.test>\nFilename: pool/{os.path.basename(deb)}\n"
            f"Size: {len(data)}\nSHA256: {hashlib.sha256(data).hexdigest()}\n"
            f"Description: OS/7 vendor lab package\n")
    sums = []
    for a, stanzas in by_arch.items():
        rel = f"main/binary-{a}/Packages"
        p = os.path.join(root, "dists", "resolute", rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        body = "\n".join(stanzas).encode()
        open(p, "wb").write(body)
        sums.append(f" {hashlib.sha256(body).hexdigest()} {len(body)} {rel}")
    release = ("Origin: VendorLab\nLabel: VendorLab\nSuite: resolute\nCodename: resolute\n"
               f"Date: {time.strftime('%a, %d %b %Y %H:%M:%S UTC', time.gmtime())}\n"
               f"Architectures: {arch} all\nComponents: main\nSHA256:\n" + "\n".join(sums) + "\n")
    rp = os.path.join(root, "dists", "resolute", "Release")
    open(rp, "w").write(release)
    r = gpg(signer_home, "--clearsign", "-o", os.path.join(root, "dists", "resolute", "InRelease"), rp)
    assert r.returncode == 0, r.stderr.decode()


# ---------------------------------------------------------------------------
# PowerShell, against a module root (the tree, or a planted copy)
# ---------------------------------------------------------------------------
def ps(script, root):
    full = (f"$ErrorActionPreference='Stop'; Import-Module {root}/OS7/OS7.psd1 -Force; "
            f"Import-Module {root}/Apt/Apt.psd1 -Force; " + script)
    r = sh(["pwsh", "-NoProfile", "-NonInteractive", "-c", full])
    last = [l for l in r.stdout.splitlines() if l.strip().startswith(("{", "["))]
    try:
        return json.loads(last[-1]) if last else {"_raw": r.stdout, "_err": r.stderr}
    except ValueError:
        return {"_raw": r.stdout, "_err": r.stderr}


def reset():
    for p in ["/etc/os7", "/var/lib/os7", "/var/log/os7"]:
        shutil.rmtree(p, ignore_errors=True)
    for d in ["/etc/apt/sources.list.d", "/etc/apt/preferences.d"]:
        for f in os.listdir(d):
            if f.startswith("os7-vendor-") or f in ("stray.list", "microsoft-edge.sources"):
                os.remove(os.path.join(d, f))
    sh(["dpkg", "--purge", "vendorapp", "vendorapp-extra", "vendorapp-archive-keyring", "strayapp"])


def files_of(name):
    return {
        "source": os.path.exists(f"/etc/apt/sources.list.d/os7-vendor-{name}.sources"),
        "pref": os.path.exists(f"/etc/apt/preferences.d/os7-vendor-{name}.pref"),
        "record": os.path.exists(f"/etc/os7/package-sources/{name}.json"),
        "keyring": any(os.path.exists(f"/etc/os7/keyrings/{name}{e}") for e in (".gpg", ".asc")),
    }


REGISTER = ("try {{ $r = Register-OS7PackageSource -Name lab -Uri '{uri}' -Suite resolute "
            "-KeyFile '{key}' -Fingerprint '{fpr}' -Package vendorapp -Confirm:$false 3>$null; "
            "@{{ threw = $null; verified = $r.Verified; intact = $r.KeyringIntact }} | ConvertTo-Json -Compress }} "
            "catch {{ @{{ threw = $_.Exception.Message; type = $_.Exception.GetType().Name }} | ConvertTo-Json -Compress }}")


def scenarios(root, k, debs, arch, only=None):
    """Run the scenarios against one module root; return {name: [(ok, what, detail)]}."""
    results = {}

    def want(name):
        return only is None or name in only

    def rec(name, ok, what, detail=""):
        results.setdefault(name, []).append((bool(ok), what, detail))

    A_home, A_key, A_fpr = k["A"]
    B_home, B_key, B_fpr = k["B"]
    base = [(debs["vendorapp1"], "vendorapp", "1.0", arch),
            (debs["keyring"], "vendorapp-archive-keyring", "1.0", "all"),
            (debs["extra"], "vendorapp-extra", "1.0", arch)]
    with11 = base + [(debs["vendorapp11"], "vendorapp", "1.1", arch)]

    # S1 -- admitted with the right key: files, record, the pin's effect on REAL apt
    if want("S1"):
        reset(); publish(A_home, base, arch)
        o = ps(REGISTER.format(uri=URI, key=A_key, fpr=A_fpr), root)
        rec("S1", o.get("threw") is None, "the right key and fingerprint are admitted", str(o.get("threw") or o.get("_err", ""))[-200:])
        rec("S1", o.get("verified") is True and o.get("intact") is True, "the index verified and the keyring holds exactly that key", json.dumps(o)[:200])
        f = files_of("lab")
        rec("S1", all(f.values()), "source, preference, record and OS/7's copy of the key exist", json.dumps(f))
        pol = sh(["apt-cache", "policy", "vendorapp", "vendorapp-archive-keyring", "vendorapp-extra"], env={**os.environ, "LC_ALL": "C.UTF-8"}).stdout
        cand = {}
        cur = None
        for line in pol.splitlines():
            if line and not line.startswith(" ") and line.endswith(":"):
                cur = line[:-1]
            elif "Candidate:" in line and cur:
                cand[cur] = line.split(":", 1)[1].strip()
        rec("S1", cand.get("vendorapp") == "1.0", "vendorapp has a candidate (500)", json.dumps(cand))
        rec("S1", cand.get("vendorapp-archive-keyring") == "(none)", "the vendor's KEYRING package has none (-1)", json.dumps(cand))
        rec("S1", cand.get("vendorapp-extra") == "(none)", "nor does anything else it publishes", json.dumps(cand))

    # S2 -- the wrong fingerprint: refused, nothing written
    if want("S2"):
        reset(); publish(A_home, base, arch)
        o = ps(REGISTER.format(uri=URI, key=A_key, fpr=B_fpr), root)
        rec("S2", bool(o.get("threw")) and "refused" in str(o.get("threw")), "a key that is not the admitted fingerprint is REFUSED", str(o)[:200])
        rec("S2", not any(files_of("lab").values()), "and nothing was written", json.dumps(files_of("lab")))

    # S3 -- a keyring that holds the admitted key AND another
    if want("S3"):
        reset(); publish(A_home, base, arch)
        both = os.path.join(LAB, "key-AB.gpg")
        open(both, "wb").write(open(A_key, "rb").read() + open(B_key, "rb").read())
        o = ps(REGISTER.format(uri=URI, key=both, fpr=A_fpr), root)
        rec("S3", bool(o.get("threw")) and "primary keys" in str(o.get("threw")), "a keyring with a SECOND primary key is refused", str(o)[:200])
        rec("S3", not any(files_of("lab").values()), "and nothing was written", json.dumps(files_of("lab")))

    # S4 -- the repository signs with another key than the one admitted
    if want("S4"):
        reset(); publish(B_home, base, arch)
        o = ps(REGISTER.format(uri=URI, key=A_key, fpr=A_fpr), root)
        rec("S4", bool(o.get("threw")) and "does not verify" in str(o.get("threw")), "a repository that does not verify against the key is refused at registration", str(o)[:240])
        rec("S4", not any(files_of("lab").values()), "and everything written is taken out again", json.dumps(files_of("lab")))

    # S5 -- the key over plain http
    if want("S5"):
        reset(); publish(A_home, base, arch)
        o = ps("try { Register-OS7PackageSource -Name lab -Uri '%s' -Suite resolute -KeyUri 'http://127.0.0.1:%d/key' "
               "-Fingerprint '%s' -Package vendorapp -Confirm:$false | Out-Null; @{threw=$null} | ConvertTo-Json -Compress } "
               "catch { @{threw=$_.Exception.Message} | ConvertTo-Json -Compress }" % (URI, PORT, A_fpr), root)
        rec("S5", bool(o.get("threw")) and "https" in str(o.get("threw")), "a key fetched over plain http is refused", str(o)[:200])

    # S6 -- the timer's verb: named packages, --only-upgrade, logged, baseline
    if want("S6"):
        reset(); publish(A_home, base, arch)
        ps(REGISTER.format(uri=URI, key=A_key, fpr=A_fpr), root)
        ps("Install-AptPackage vendorapp -NoInstallRecommends -Confirm:$false | Out-Null; '{}'", root)
        publish(A_home, with11, arch)
        hist_before = open("/var/log/apt/history.log").read() if os.path.exists("/var/log/apt/history.log") else ""
        o = ps("$r = @(Update-OS7PackageSource -Name lab -Confirm:$false); @{ moved = @($r[0].Moved); err = $r[0].Error; verified = $r[0].Verified } | ConvertTo-Json -Compress", root)
        rec("S6", o.get("verified") is True and any("vendorapp 1.0 -> 1.1" in m for m in o.get("moved") or []), "vendorapp moved 1.0 -> 1.1", json.dumps(o)[:200])
        hist = open("/var/log/apt/history.log").read()[len(hist_before):] if os.path.exists("/var/log/apt/history.log") else ""
        cmds = [l for l in hist.splitlines() if l.startswith("Commandline:")]
        rec("S6", any("--only-upgrade" in c and "vendorapp" in c for c in cmds), "as `install --only-upgrade vendorapp`", "; ".join(cmds)[:200])
        rec("S6", not any("full-upgrade" in c or c.rstrip().endswith(" upgrade") for c in cmds), "and never a full-upgrade", "; ".join(cmds)[:200])
        log = open("/var/log/os7/vendor-update.log").read() if os.path.exists("/var/log/os7/vendor-update.log") else ""
        rec("S6", "lab: vendorapp 1.0 -> 1.1" in log, "the move is in /var/log/os7/vendor-update.log", log[-200:])
        bl = open("/var/lib/os7/packages.baseline").read() if os.path.exists("/var/lib/os7/packages.baseline") else ""
        rec("S6", "vendorapp\t1.1\t" in bl, "and the package baseline was rewritten with it", bl[:120])

    # S7 -- somebody replaced the keyring under the source
    if want("S7"):
        reset(); publish(A_home, base, arch)
        ps(REGISTER.format(uri=URI, key=A_key, fpr=A_fpr), root)
        shutil.copy(B_key, "/etc/os7/keyrings/lab.gpg")
        o = ps("$g = Get-OS7PackageSource -Name lab; $u = @(Update-OS7PackageSource -Name lab -Confirm:$false); "
               "@{ intact = $g.KeyringIntact; attention = @($g.Attention); err = $u[0].Error; verified = $u[0].Verified } | ConvertTo-Json -Compress", root)
        rec("S7", o.get("intact") is False and any("keyring changed" in a for a in o.get("attention") or []), "Get- says the keyring changed", json.dumps(o)[:220])
        rec("S7", o.get("verified") is False and "keyring changed" in str(o.get("err")), "and Update- installs nothing from it", json.dumps(o)[:220])

    # S8 -- the vendor rotated its key: the index no longer verifies
    if want("S8"):
        reset(); publish(A_home, base, arch)
        ps(REGISTER.format(uri=URI, key=A_key, fpr=A_fpr), root)
        publish(B_home, base, arch)
        o = ps("$u = @(Update-OS7PackageSource -Name lab -Confirm:$false); $g = Get-OS7PackageSource -Name lab; "
               "@{ verified = $u[0].Verified; err = $u[0].Error; gv = $g.Verified; last = $g.LastError; attention = @($g.Attention) } | ConvertTo-Json -Compress", root)
        rec("S8", o.get("verified") is False and o.get("gv") is False, "an index signed by another key is NOT verified (exit 0 would have said it was)", json.dumps(o)[:240])
        rec("S8", "NO_PUBKEY" in str(o.get("last")), "and the record carries apt's reason", str(o.get("last"))[:160])
        rec("S8", any("has not verified since" in a for a in o.get("attention") or []), "with a date it last did", json.dumps(o.get("attention"))[:200])

    # S9 -- every other source has a class
    if want("S9"):
        reset(); publish(A_home, base, arch)
        ps(REGISTER.format(uri=URI, key=A_key, fpr=A_fpr), root)
        open("/etc/apt/sources.list.d/stray.list", "w").write(f"deb [trusted=yes] {URI} resolute main\n")
        shutil.copy(os.path.join(REPO_IN, "powershell", "Apt", "tests", "fixtures", "etc-apt", "sources.list.d", "microsoft-edge.sources"),
                    "/etc/apt/sources.list.d/microsoft-edge.sources")
        o = ps("@(Get-OS7PackageSource -All | ForEach-Object { @{ n = $_.Name; c = $_.Class; a = @($_.Attention) } }) | ConvertTo-Json -Compress -Depth 4", root)
        cls = {x["n"]: x["c"] for x in (o if isinstance(o, list) else [])}
        att = {x["n"]: x["a"] for x in (o if isinstance(o, list) else [])}
        rec("S9", cls.get("lab") == "Registered", "the registered source is Registered", json.dumps(cls))
        rec("S9", cls.get("stray.list") == "Unregistered" and any("unconfined" in a or "nothing confining" in a for a in att.get("stray.list") or []), "a stray .list is Unregistered, and says what that means", json.dumps(cls))
        rec("S9", cls.get("microsoft-edge.sources") == "Image", "Edge's file is Image", json.dumps(cls))
        rec("S9", cls.get("ubuntu.sources") == "Release", "the archive's file is Release", json.dumps(cls))

    # S10 -- unregistering
    if want("S10"):
        reset(); publish(A_home, base, arch)
        ps(REGISTER.format(uri=URI, key=A_key, fpr=A_fpr), root)
        ps("Install-AptPackage vendorapp -NoInstallRecommends -Confirm:$false | Out-Null; '{}'", root)
        o = ps("try { Unregister-OS7PackageSource lab -Confirm:$false | Out-Null; @{threw=$null} | ConvertTo-Json -Compress } catch { @{threw=$_.Exception.Message} | ConvertTo-Json -Compress }", root)
        rec("S10", bool(o.get("threw")) and "still supplies vendorapp" in str(o.get("threw")), "refused while it still supplies an installed package", str(o)[:200])
        ps("Unregister-OS7PackageSource lab -Force -Confirm:$false | Out-Null; '{}'", root)
        rec("S10", not any(files_of("lab").values()) and not os.path.exists("/var/lib/os7/package-sources/lab.json"), "-Force removes source, preference, key, record and status", json.dumps(files_of("lab")))

    # S11 -- drift against the baseline, in classes
    if want("S11"):
        reset(); publish(A_home, base, arch)
        ps(REGISTER.format(uri=URI, key=A_key, fpr=A_fpr), root)
        ps("Install-AptPackage vendorapp -NoInstallRecommends -Confirm:$false | Out-Null; Save-OS7PackageBaseline -Reason test -Confirm:$false | Out-Null; '{}'", root)
        publish(A_home, with11, arch)
        env = {**os.environ, "LC_ALL": "C.UTF-8", "DEBIAN_FRONTEND": "noninteractive"}
        # `onlydir` AND NOT `only`: `only` is this function's parameter, and
        # rebinding it here made want("S12") ask whether "S12" is a substring of
        # a PATH — so S12 was skipped in every full run, silently, while it
        # passed when run alone. BUILD-NOTES #65's shape, in Python.
        onlydir = os.path.join(LAB, "only")
        os.makedirs(onlydir, exist_ok=True)
        shutil.copy("/etc/apt/sources.list.d/os7-vendor-lab.sources", onlydir)
        sh(["apt-get", "update", "-qq", "-o", "Dir::Etc::SourceList=/dev/null",
            "-o", "Dir::Etc::SourceParts=" + onlydir, "-o", "APT::List-Cleanup=0"], env=env)
        sh(["apt-get", "install", "-y", "-qq", "vendorapp"], env=env)        # by hand: Intended
        sh(["dpkg", "-i", debs["stray"]], env=env)                           # by hand: Unexplained
        o = ps("$d = (Get-OS7Version -CheckDrift).Drift; @{ ref = $d.Reference; state = $d.State; i = @($d.Intended); u = @($d.Unexplained) } | ConvertTo-Json -Compress", root)
        rec("S11", o.get("ref") == "Baseline" and o.get("state") == "Drifted", "drift is measured against the baseline", json.dumps(o)[:200])
        rec("S11", "vendorapp" in (o.get("i") or []), "a registered source's package moving is Intended", json.dumps(o)[:200])
        rec("S11", "strayapp" in (o.get("u") or []) and "vendorapp" not in (o.get("u") or []), "a package from nowhere is Unexplained, and only it", json.dumps(o)[:200])

    # S12 -- the drift function itself: no baseline, and a recorded hash
    if want("S12"):
        reset()
        o = ps("$m = Get-Module OS7; $d = & $m { Get-OS7PackageDrift -Recorded '' -BaselinePath '/nonexistent' }; "
               "$e = & $m { try { $x = Get-OS7PackageDrift -Recorded 'sha256:00' -BaselinePath '/nonexistent'; @{ s = $x.State; r = $x.Reference; t = $null } } catch { @{ t = $_.Exception.Message } } }; "
               "@{ unknown = $d.State; withHash = $e } | ConvertTo-Json -Compress -Depth 4", root)
        rec("S12", o.get("unknown") == "Unknown", "no baseline and no recorded hash is Unknown, never Clean", json.dumps(o)[:200])
        w = o.get("withHash") or {}
        rec("S12", w.get("t") is None and w.get("s") == "Drifted" and w.get("r") == "Image", "with a hash and no -Installed it ASKS dpkg and answers (it used to throw: @($null))", json.dumps(w)[:200])
    # S13 -- a source for the same repository with ANOTHER keyring (the vendor's
    # documented install): apt then refuses every source (measured on 1.0.0.279)
    if want("S13"):
        reset(); publish(A_home, base, arch)
        stray_line = f"deb [signed-by=/usr/share/keyrings/vendorapp-archive-keyring.gpg] {URI} resolute main" + chr(10)
        open("/etc/apt/sources.list.d/stray.list", "w").write(stray_line)
        o = ps(REGISTER.format(uri=URI, key=A_key, fpr=A_fpr), root)
        rec("S13", bool(o.get("threw")) and "stray.list" in str(o.get("threw")), "registering beside a source with another keyring is refused, naming the file", str(o)[:240])
        rec("S13", not any(files_of("lab").values()), "and nothing was written", json.dumps(files_of("lab")))
        os.remove("/etc/apt/sources.list.d/stray.list")
        ps(REGISTER.format(uri=URI, key=A_key, fpr=A_fpr), root)
        open("/etc/apt/sources.list.d/stray.list", "w").write(stray_line)
        apt = sh(["apt-get", "update"], env={**os.environ, "LC_ALL": "C.UTF-8"})
        rec("S13", apt.returncode != 0 and "Conflicting values set for option Signed-By" in apt.stderr + apt.stdout,
            "(the control: apt itself refuses every source then)", (apt.stderr + apt.stdout)[-160:])
        o = ps("@(Get-OS7PackageSource -All | Where-Object Name -eq 'stray.list' | ForEach-Object { @($_.Attention) }) | ConvertTo-Json -Compress", root)
        att = o if isinstance(o, list) else []
        rec("S13", any("REFUSES EVERY SOURCE" in a for a in att), "Get-OS7PackageSource -All says what the stray file does", json.dumps(att)[:200])
    return results


# The planted defects: (file under powershell/, old, new, scenario that must go red)
PLANTS = [
    ("fingerprint not compared", "OS7/OS7.PackageSource.ps1",
     [("$intact = ($found.Count -eq 1 -and $found[0] -eq $Fingerprint)", "$intact = $true")], "S2"),
    ("no `Package: *` at -1", "OS7/OS7.PackageSource.ps1",
     [("@{ Package = '*'; Pin = \"origin $($u.Host)\"; Priority = -1 },", "")], "S1"),
    # BOTH halves of the fail-loud rule, because either alone catches it: the
    # switch makes apt exit 100, and the lines are there at exit 0 as well.
    ("apt asked without --error-on, judged by exit code", "Apt/Apt.psm1",
     [("$argv = @('update', '--error-on=any')", "$argv = @('update')"),
      ("Succeeded  = ($ExitCode -eq 0 -and $errors.Count -eq 0 -and $failures.Count -eq 0)",
       "Succeeded  = ($ExitCode -eq 0)")], "S8"),
    ("the timer without --only-upgrade", "OS7/OS7.PackageSource.ps1",
     [("-OnlyUpgrade -NoInstallRecommends -Confirm:$false", "-NoInstallRecommends -Confirm:$false")], "S6"),
    ("every source called Release", "OS7/OS7.PackageSource.ps1",
     [("\treturn 'Unregistered'\n", "\treturn 'Release'\n")], "S9"),
    ("@($Installed) again", "OS7/OS7.psm1",
     [("$raw = @($Installed | Where-Object { $_ })", "$raw = @($Installed)")], "S12"),
    ("no Signed-By clash check", "OS7/OS7.PackageSource.ps1",
     [("\tif ($clash.Count) {\n", "\tif ($false) {\n")], "S13"),
    ("no rollback of a failed registration", "OS7/OS7.PackageSource.ps1",
     [("\t\tforeach ($w in $written) { Remove-Item -Force -ErrorAction SilentlyContinue $w }\n", "")], "S4"),
]

REPO_IN = "/work"


def inside(prove):
    global REPO_IN
    shutil.rmtree(LAB, ignore_errors=True)
    os.makedirs(LAB)
    arch = sh(["dpkg", "--print-architecture"]).stdout.strip()
    print("\n### vendor package sources against real apt (%s)" % arch)
    keys = {"A": make_key("A"), "B": make_key("B")}
    debs = {
        "vendorapp1": build_deb("vendorapp", "1.0", arch),
        "vendorapp11": build_deb("vendorapp", "1.1", arch),
        "keyring": build_deb("vendorapp-archive-keyring", "1.0", "all"),
        "extra": build_deb("vendorapp-extra", "1.0", arch),
        "stray": build_deb("strayapp", "1.0", arch),
    }
    os.makedirs(os.path.join(LAB, "www"), exist_ok=True)
    server = subprocess.Popen([sys.executable, "-m", "http.server", str(PORT), "--bind", "127.0.0.1",
                               "--directory", os.path.join(LAB, "www")],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1)
    bad = 0
    try:
        print("  the Apt module's own self-test")
        st = sh(["pwsh", "-NoProfile", "-NonInteractive", "-c",
                 "Import-Module /work/powershell/Apt/Apt.psd1 -Force; Test-AptModule"])
        verdict = [l for l in st.stderr.splitlines() if "Apt self-test:" in l]
        ok = st.returncode == 0 and any("PASS" in l for l in verdict)
        print("      %s  Test-AptModule on Linux — %s" % ("ok  " if ok else "FAIL", "; ".join(verdict)))
        bad += 0 if ok else 1

        res = scenarios("/work/powershell", keys, debs, arch)
        expected = {f"S{i}" for i in range(1, 14)}
        if set(res) != expected:
            print("      FAIL  scenarios that recorded nothing: %s" % sorted(expected - set(res)))
            bad += 1
        for name in sorted(res, key=lambda s: int(s[1:])):
            print(f"\n  {name}")
            for ok, what, detail in res[name]:
                print("      %s  %s%s" % ("ok  " if ok else "FAIL", what, "" if ok else f"   [{detail}]"))
                bad += 0 if ok else 1

        if prove:
            print("\n  every rule proven to fire: a planted defect per rule, each in a copy")
            for what, rel, edits, scen in PLANTS:
                copy = tempfile.mkdtemp(dir=LAB)
                shutil.copytree("/work/powershell", os.path.join(copy, "powershell"))
                p = os.path.join(copy, "powershell", rel)
                s = open(p, encoding="utf-8").read()
                missing = [o for o, _ in edits if s.count(o) != 1]
                if missing:
                    print(f"      FAIL  plant '{what}': text to change not in {rel} exactly once: {missing[0][:50]!r}")
                    bad += 1
                    continue
                for o, n in edits:
                    s = s.replace(o, n, 1)
                open(p, "w", encoding="utf-8").write(s)
                r = scenarios(os.path.join(copy, "powershell"), keys, debs, arch, only={scen})
                red = [w for ok, w, _ in r.get(scen, []) if not ok]
                print("      %s  %-40s -> %s %s" % ("ok  " if red else "FAIL", what, scen,
                                                    f"RED ({red[0]})" if red else "stayed GREEN"))
                bad += 0 if red else 1
                shutil.rmtree(copy, ignore_errors=True)
    finally:
        server.terminate()
        reset()
    print()
    print("vendor package sources: %s" % ("GREEN" if not bad else f"RED, {bad} failed"))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in-container", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--no-prove", action="store_true", help="skip the planted defects")
    args = ap.parse_args()
    if args.in_container:
        sys.exit(inside(not args.no_prove))

    img = sh(["docker", "image", "inspect", IMAGE])
    if img.returncode != 0:
        sys.exit(f"{IMAGE} is not built. ./installer/testing/check-update-logic.py builds it "
                 "(the same pinned pwsh, gnupg, python3).")
    argv = ["docker", "run", "--rm", "-v", REPO + ":/work:ro", IMAGE,
            "python3", "/work/installer/testing/check-package-source-logic.py", "--in-container"]
    if args.no_prove:
        argv.append("--no-prove")
    r = subprocess.run(argv)
    sys.exit(r.returncode)


if __name__ == "__main__":
    main()
