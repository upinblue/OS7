# OS/7 Versions — the file manager's context-menu entry.
#
# docs/VERSIONS-PLAN.md V3. THIS FILE IS THE WHOLE OF THE COUPLING between OS/7
# and whatever file manager is installed, and it is deliberately this small:
# `os7-versions <absolute path>` is the entire contract. The day OS/7 ships a
# different file manager, only this file is rewritten — nothing in the
# application, nothing in the cmdlets, nothing in the plan.
#
# SO IT DECIDES NOTHING. It does not ask whether the path is on ZFS, whether the
# dataset is snapshotted, or whether there are any versions to show: every one of
# those is a question with a careful answer already written in
# `Get-OS7FileVersion`, reached through the window, and a menu item that
# disappeared on a machine where the answer was "this file has no history yet"
# would hide exactly the sentence the operator needs (V6). The entry is always
# offered for a local file or folder; the window explains.
#
# IT IS ENGLISH ONLY, like the rest of the family in v1 (GUI-APPS-PLAN). The
# German "Versionen" is a translation job for the whole product, not a string to
# get half-right here.

import subprocess

# NO gi.require_version("Nautilus", …) HERE, AND THAT IS A MEASUREMENT.
#
# The first version of this file called `gi.require_version("Nautilus", "4.0")`,
# which is what every nautilus-python example on the internet opens with. On a
# machine installed from the medium it threw:
#
#     ValueError: Namespace Nautilus is already loaded with version 4.1
#
# Two things wrong in one line. The namespace on GNOME 50 is **4.1** — the image
# carries `Nautilus-4.1.typelib` and no 4.0 at all — and, more importantly,
# nautilus-python has ALREADY required it before it imports any extension. So the
# call cannot succeed and cannot be needed: pinning it right would only fix the
# error message and break again on the next GNOME.
#
# AND THE FAILURE IS SILENT. Nautilus logs the traceback to the session journal
# and carries on with no menu entry — which looks exactly like a machine where
# the package was never installed. Nothing short of a real desktop finds it;
# the package build checks that this file PARSES, and a file that parses is not
# yet a file Nautilus can load.
from gi.repository import GObject, Nautilus

OS7_VERSIONS = "/usr/lib/os7/apps/versions/os7-versions"


class OS7VersionsExtension(GObject.GObject, Nautilus.MenuProvider):
    """A single menu item, for a single local file or folder."""

    def get_file_items(self, *args):
        # THE SIGNATURE MOVED. nautilus-python 3.x passed (window, files) and
        # 4.x passes (files); taking the last positional argument works under
        # both, and this package is pinned against neither forever.
        files = args[-1] if args else []

        if len(files) != 1:
            # "Versions" is a question about ONE file's history. Offering it for
            # a selection of forty would promise a window this application does
            # not have.
            return []

        item = files[0]

        # Anything that is not a local path has no ZFS snapshots to read: a
        # file on a remote share, in the trash, or inside an archive. The
        # window's own refusal would be right but slower and stranger than not
        # offering the entry.
        if item.get_uri_scheme() != "file":
            return []

        entry = Nautilus.MenuItem(
            name="OS7Versions::Show",
            label="Versions",
            tip="Show previous versions of this item",
        )
        entry.connect("activate", self._open, item)
        return [entry]

    def _open(self, _menu, item):
        # get_location().get_path() rather than un-escaping the URI by hand: a
        # file called `Angebot #2 (Entwurf).txt` is ordinary, and every character
        # in it is percent-encoded in the URI. Gio already owns that conversion.
        location = item.get_location()
        path = location.get_path() if location is not None else None
        if not path:
            return

        # A LIST, NEVER A COMMAND LINE. The argument is a filename and a
        # filename may contain anything but NUL and '/', including quotes,
        # spaces, newlines and `; rm -rf ~ #`. Popen with a list never builds a
        # shell command for any of it to escape from.
        subprocess.Popen([OS7_VERSIONS, path])
