#!/usr/bin/env python3
"""
OS/7 — the /etc/os-release identity, in one place.

    os-release-identity.py rewrite <path>     brand it, in place
    os-release-identity.py check   <path>     assert it is branded and intact

docs/IDENTITY-PLAN.md §4 and I1-I4 are the design; this is its implementation.
It reads OS7_PRODUCT, OS7_VERSION, OS7_VARIANT and OS7_VARIANT_ID from the
environment and composes NOTHING — the display rule lives in
build/lib/version-rule.sh and its output is handed in (IDENTITY-PLAN §5).

WHY THIS IS A FILE AND NOT A HEREDOC INSIDE HOOK 0075. Since C7 there are TWO
writers of this file and they must not be two implementations:

  * hook 0075, which brands the image while live-build is building it, and
  * os7-release's postinst, which brands an INSTALLED machine after dpkg has
    put base-files' own version back.

The second one is the point of CURATION-AND-DELIVERY-PLAN §6.2:
`/etc/os-release` is a symlink to `/usr/lib/os-release`, base-files owns that as
a CONFFILE, and every `apt` run that touches base-files can revert the branding.
UL10 mitigates that with "a step in the update sequence that has to be
remembered forever". A step that has to be remembered forever is a defect, so
os7-release diverts the file and owns the identity — and then the two writers
had better agree to the byte.

THE FIELDS THAT MUST NOT BE TOUCHED are `PROTECTED` below, and the list is a
measurement rather than a preference. BUILD-NOTES #80: three Microsoft
consumers read three different field sets, Azure Arc's onboarding script keys on
NAME and exits 133 without ever reading ID, and D8 branded NAME on the strength
of a guess about a different tool. Never protect "the field they match on" —
make the brand independent of all of them.
"""
import os
import sys


# Ubuntu's privacy policy is not OS/7's, and pointing a user at a document that
# does not describe this system is worse than pointing them at none.
DROP = {"PRIVACY_POLICY_URL"}

# Somebody else's fields. Named here so that adding a field to the brand can
# never silently capture one of them (IDENTITY-PLAN I4).
PROTECTED = {"ID", "ID_LIKE", "VERSION_ID", "VERSION", "VERSION_CODENAME",
             "UBUNTU_CODENAME", "NAME"}

# The two fields whose VALUES are the compatibility promise rather than merely
# unchanged: Intune's "Allowed distributions" rule is evaluated by the service
# from what `intune-agent` reads here.
LITERAL_CONTRACT = {"ID": "ubuntu", "VERSION_ID": "26.04"}


def quote(value):
    """os-release(5) values are shell-quoted. ALWAYS double quotes, never the
    single quotes shlex.quote would pick: os-release is meant to be sourced by
    `.`, and every other line in the file Ubuntu ships is double-quoted. A file
    mixing both styles still parses, but it invites a reader that strips only
    one of them — which is a bug hook 0075's own readback check had before it
    was written to source the file instead of scraping it (BUILD-NOTES #37)."""
    escaped = value.replace("\\", "\\\\")
    for ch in '"$`':
        escaped = escaped.replace(ch, "\\" + ch)
    return '"' + escaped + '"'


def brand_fields(env):
    """The branded fields, in the order they should appear if they are new.

    PRETTY_NAME is the THREE-field form with the channel — "OS/7 1.0.0
    (development)" — because it describes rather than identifies. IMAGE_VERSION
    right below it is all FOUR, because it identifies. Both are handed in;
    neither is composed here (IDENTITY-PLAN §5)."""
    missing = [k for k in ("OS7_PRODUCT", "OS7_VERSION",
                           "OS7_VARIANT", "OS7_VARIANT_ID") if not env.get(k)]
    if missing:
        raise SystemExit("os-release-identity: " + ", ".join(missing) + " not set")
    return {
        "PRETTY_NAME":       env["OS7_PRODUCT"],
        "IMAGE_ID":          "os7",
        "IMAGE_VERSION":     env["OS7_VERSION"],
        "VARIANT":           env["OS7_VARIANT"],
        "VARIANT_ID":        env["OS7_VARIANT_ID"],
        "HOME_URL":          "https://github.com/upinblue/OS7",
        # Where a person goes when the product misbehaves. Leaving Ubuntu's is
        # WORSE than leaving these unset: it sends OS/7's bugs to Canonical.
        "SUPPORT_URL":       "https://github.com/upinblue/OS7/issues",
        "BUG_REPORT_URL":    "https://github.com/upinblue/OS7/issues",
        "DOCUMENTATION_URL": "https://github.com/upinblue/OS7",
        "LOGO":              "os7",
        # The brand blue, #1289ff (SETUP-PLAN D5), as a truecolor SGR parameter
        # string. hostnamectl and the fetch tools use it; a terminal without
        # truecolor ignores the sequence rather than mangling it.
        "ANSI_COLOR":        "0;38;2;18;137;255",
    }


def read(path):
    """Every field, the way a real consumer reads it: by parsing the shell
    assignment and accepting both quote styles, never by stripping one."""
    out = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                value = value[1:-1]
            out[key.strip()] = value
    return out


def rewrite(path, env):
    brand = brand_fields(env)
    assert not (PROTECTED & brand.keys()), "tried to brand a protected field"
    assert not (PROTECTED & DROP), "tried to delete a protected field"

    before = read(path)

    lines, seen = [], set()
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            key = line.split("=", 1)[0].strip() if "=" in line else None
            if key in DROP:
                continue
            if key in brand:
                lines.append(key + "=" + quote(brand[key]))
                seen.add(key)
            else:
                lines.append(line)

    for key, value in brand.items():
        if key not in seen:
            lines.append(key + "=" + quote(value))

    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    # Read it BACK. A writer that does not re-read is the shape of every
    # expensive bug in docs/BUILD-NOTES.md.
    check(path, env, before=before)


def check(path, env, before=None):
    """Assert the branded fields changed and the untouchable ones did not.

    `before` makes the second half a real check rather than a comparison
    against a literal somebody typed here — a literal passes for a file that was
    mangled into the same wrong value the checker expected."""
    brand = brand_fields(env)
    got = read(path)
    bad = []

    for key, want in brand.items():
        if got.get(key) != want:
            bad.append("%s is %r, expected %r" % (key, got.get(key), want))

    for key, want in LITERAL_CONTRACT.items():
        if got.get(key) != want:
            bad.append("%s is %r, expected %r — Intune's 'Allowed distributions' "
                       "rule reads this field" % (key, got.get(key), want))

    # NAME as a GLOB and not as a literal, because the glob IS the contract:
    # Install_linux_azcmagent.sh does `case "${distro}" in *buntu*)` and exits
    # 133 on anything else, having read NAME and never ID. Asserting
    # NAME=Ubuntu would also pass today and would be asserting the wrong thing.
    if "buntu" not in got.get("NAME", ""):
        bad.append("NAME is %r, which contains no 'buntu' — Azure Arc's "
                   "onboarding script reads THIS field and exits 133 otherwise "
                   "(BUILD-NOTES #80, IDENTITY-PLAN I2)" % (got.get("NAME"),))

    for key in DROP:
        if got.get(key):
            bad.append(key + " is still set; it should have been dropped")

    if before is not None:
        for key in PROTECTED:
            if before.get(key) != got.get(key):
                bad.append("%s changed from %r to %r — that field is somebody "
                           "else's (IDENTITY-PLAN I4)"
                           % (key, before.get(key), got.get(key)))

    if bad:
        for line in bad:
            print("os-release-identity: " + line, file=sys.stderr)
        raise SystemExit(1)


def main(argv):
    if len(argv) != 3 or argv[1] not in ("rewrite", "check"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    action, path = argv[1], argv[2]
    if not os.path.isfile(path):
        print("os-release-identity: " + path + " does not exist", file=sys.stderr)
        return 1
    (rewrite if action == "rewrite" else check)(path, os.environ)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
