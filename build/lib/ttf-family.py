#!/usr/bin/env python3
"""OS/7 — read the family name out of a TrueType font, and assert it.

Why this exists at all: the desktop theme selects its UI font BY NAME, in
`/etc/dconf/db/os7.d/00-os7-classic`:

    font-name='Tahoma 9'

fontconfig resolves an unknown family to the default sans face silently. So a
font file whose internal family name is not `Tahoma` produces a system that
looks almost right, reports no error anywhere, and is not running the font the
theme asked for. That is the failure shape this repository keeps paying for —
a program reports success and the thing it was meant to change did not change.

The check has to read the FONT, not the filename and not the package metadata:
a diagnostic must not depend on the subsystem it is diagnosing.

    ttf-family.py show    FONT...
    ttf-family.py verify  --expect "Tahoma:Regular" FONT
"""

import argparse
import struct
import sys

# name table IDs, OpenType spec: 1 family, 2 subfamily, 4 full name.
NAME_FAMILY = 1
NAME_SUBFAMILY = 2
NAME_FULL = 4


def read_names(path):
    """Return {nameID: str} from a font's `name` table."""
    with open(path, "rb") as handle:
        data = handle.read()

    if len(data) < 12:
        raise ValueError(f"{path}: too short to be a font")

    num_tables = struct.unpack(">H", data[4:6])[0]
    table = None
    for index in range(num_tables):
        entry = 12 + 16 * index
        if data[entry:entry + 4] == b"name":
            table = struct.unpack(">II", data[entry + 8:entry + 16])[0]
            break
    if table is None:
        raise ValueError(f"{path}: no `name` table")

    _fmt, count, strings = struct.unpack(">HHH", data[table:table + 6])
    names = {}
    for index in range(count):
        record = table + 6 + 12 * index
        platform, _enc, _lang, name_id, length, offset = struct.unpack(
            ">HHHHHH", data[record:record + 12]
        )
        raw = data[table + strings + offset:table + strings + offset + length]
        try:
            # Platform 3 (Windows) is UTF-16BE; platform 1 (Mac) is single byte.
            text = raw.decode("utf-16-be") if platform == 3 else raw.decode("latin-1")
        except UnicodeDecodeError:
            continue
        # First record for an ID wins: Windows records come first in practice,
        # and any of them carries the same family name.
        names.setdefault(name_id, text)
    return names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    show = sub.add_parser("show", help="print family/subfamily/full name")
    show.add_argument("fonts", nargs="+")

    verify = sub.add_parser("verify", help="fail unless the font says what it must")
    verify.add_argument("--expect", required=True,
                        help="Family:Subfamily, e.g. Tahoma:Regular")
    verify.add_argument("font")

    args = parser.parse_args()

    if args.command == "show":
        for path in args.fonts:
            names = read_names(path)
            print(f"{path}\tfamily={names.get(NAME_FAMILY)!r}"
                  f"\tsubfamily={names.get(NAME_SUBFAMILY)!r}"
                  f"\tfull={names.get(NAME_FULL)!r}")
        return 0

    want_family, _, want_sub = args.expect.partition(":")
    names = read_names(args.font)
    got_family = names.get(NAME_FAMILY)
    got_sub = names.get(NAME_SUBFAMILY)

    if got_family != want_family or (want_sub and got_sub != want_sub):
        print(f"!!! {args.font}: font says family={got_family!r} subfamily={got_sub!r},"
              f" expected {want_family!r}:{want_sub!r}", file=sys.stderr)
        print("!!! The theme selects this font by name. A mismatch means fontconfig",
              file=sys.stderr)
        print("!!! silently substitutes the default sans face and nothing reports it.",
              file=sys.stderr)
        return 1

    print(f"    {args.font}: family={got_family!r} subfamily={got_sub!r} - as expected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
