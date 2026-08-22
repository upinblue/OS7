# OS/7 installer — Calamares + ZFS

**Status: not started.** This directory is empty apart from this file. No
Calamares configuration exists yet.

## Intent

Per the root [README.md](../README.md), the installer is Calamares plus its ZFS
module — chosen as the best available option for a customizable, brandable
installer on a ZFS-root Ubuntu derivative.

It has to do two things that off-the-shelf Calamares does not do out of the box:

1. **Install to a ZFS root**, laid out so the OS/7 release train
   (`Update-OS7` / `Restore-OS7`) can create and activate boot environments.
2. **Ask GUI vs. headless at setup time**, and install a different package set
   for each — GNOME + Microsoft Edge + Intune for GUI, no desktop packages plus
   the Azure Connected Machine agent for headless.

## Why this is the hard part

This is Open Question #3 in the root README, and the project's known hard part.
The unknown is not Calamares itself but the seam between three moving pieces:

- **live-build** produces the live medium and the squashfs that gets unpacked;
- **Calamares** unpacks it and configures the target;
- **ZFS root** changes what "the target" even looks like — datasets and boot
  environments rather than a partition with a filesystem on it.

Nobody has validated how far Calamares' ZFS module actually gets with that
combination. Assume nothing works until it has been run.

## Blocked on

Open Question #1 — the ZFS-on-Linux-7.0 warning
([openzfs/zfs#18488](https://github.com/openzfs/zfs/issues/18488)). If ZFS root
turns out not to be safe to build on for 26.04, the installer's whole storage
design changes, and any Calamares work done first is wasted. Validate that
first.
