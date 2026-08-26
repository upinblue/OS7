"""
The version DISPLAY RULE, in Python. docs/IDENTITY-PLAN.md §5.

    from os7version import friendly, short, full, product

ONE version number exists — MAJOR.MINOR.PATCH.BUILD, pinned in
build/config/os7-release.conf — and two ways of showing it, chosen by one
question: does this number IDENTIFY a thing, or DESCRIBE one? Describe gives
three fields, identify gives four, and a channel that is not `stable` names
itself in brackets in both forms.

WHY THIS FILE EXISTS RATHER THAN A HELPER INSIDE EACH HARNESS. The rule already
has four implementations — C# (`Model/Release.cs`), PowerShell
(`Get-OS7Version`), shell (`build/lib/version-rule.sh`) and this one — and the
harnesses that read a version off a screen or out of an image need it too.
`run-phase1.py` had its own copy for about an hour, which is how long it takes
for a fifth to become a sixth.

`check-version-rule.py` owns the case table and checks THIS module against it
first, then the other three against the same table. So this is the Python
implementation and not the specification; the table is the specification.
"""


def friendly(version):
    """The first three fields — "1.0.0" out of "1.0.0.95".

    Fewer than four fields comes back unchanged rather than padded, and more
    than four keeps the first three. Nothing should produce either — build.sh
    composes exactly four — but this reads a version out of a file, and a file
    can hold anything.
    """
    if not version:
        return None
    fields = version.split(".")
    return version if len(fields) <= 3 else ".".join(fields[:3])


def _format(number, channel):
    """An empty version is "unknown" rather than a plausible-looking number, and
    an empty channel is "unknown" rather than silently stable — a preview build
    mistaken for a released one is the whole reason the channel field exists."""
    if not number:
        return "unknown"
    if not channel:
        channel = "unknown"
    return number if channel == "stable" else f"{number} ({channel})"


def short(version, channel):
    """What a person is shown: "1.0.0 (development)"."""
    return _format(friendly(version), channel)


def full(version, channel):
    """What identifies a build: "1.0.0.95 (development)"."""
    return _format(version, channel)


def product(version, channel):
    """The product line PRETTY_NAME, /etc/issue and the MOTD header all carry:
    "OS/7 1.0.0 (development)"."""
    return f"OS/7 {short(version, channel)}"


def of_manifest(manifest):
    """(short, full, product) from a parsed release.json, so a caller does not
    have to remember which key the channel lives under."""
    version = manifest.get("version", "")
    channel = manifest.get("channel", "")
    return short(version, channel), full(version, channel), product(version, channel)
