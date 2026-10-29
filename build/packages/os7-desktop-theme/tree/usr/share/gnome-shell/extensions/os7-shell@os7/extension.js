// OS/7 Shell - ONE JOB: a session opens on the desktop, not in the overview.
//
// GNOME Classic starts every session in the Activities overview, with a dock of
// favourites over a black screen; Windows starts on the desktop. GNOME has no
// setting for it - measured on an install from OS7-1.0.0.245-amd64.iso, where
// the first thing after every login was that overview. Owner's decision
// 2026-10-29 (docs/DECISIONS.md, GUI mode): an OS/7-owned extension, the one
// exception to "GNOME's own extensions only", and therefore kept to the size
// you can read in one screen. Its shell-version is checked against the
// installed gnome-shell at build time (hook 0090) and in the shipped image
// (check-image.py), because an extension that does not declare the running
// Shell is skipped in silence.
//
// HOW, AND WHY NOT THE WELL-KNOWN WAY. Extensions for older GNOME did this by
// telling the session mode it had no overview for the length of the start-up.
// GNOME 50 enables user extensions only AFTER start-up - measured on 1.0.0.247,
// logged from enable(): `startingUp=false overviewVisible=true` - so by the
// time this runs the overview is already on screen and there is no start-up to
// intervene in. The first version did that, was ACTIVE, logged no error, and
// changed nothing. So: on the FIRST enable of the session, close the overview
// if it is open. Every later enable - the Shell disables extensions at the lock
// screen and enables them again on unlock - leaves the overview alone, because
// a person who had it open before locking expects it back.
//
// AND NOT WHILE IT IS STILL OPENING (BUILD-NOTES #177). The second version
// called hide() the moment it was enabled, and on a fresh 1.0.0.247 install
// the desktop came up DEAD: no key, no click, no window list, nothing in the
// journal, until the overview was opened and closed again over D-Bus. Twice
// in twenty-two logins - rare, and never caught with a probe in it.
// enable() runs inside the overview's start-up animation as often as after it
// (logged: `state=SHOWING` in one login, `SHOWN` in the next), and overview.js's
// runStartupAnimation() runs without _animationInProgress, so a hide() then
// starts a second animation over the first; GNOME's own code only expects
// that as "Overview got hidden during startup animation" and returns. Hiding
// from SHOWN is the path Escape takes. So: hide once the overview has
// FINISHED opening, and stand down if anything else closes it first.
import GLib from 'gi://GLib';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

// Module scope: the module is imported once per Shell process, and the
// Extension instance outlives disable(), so this is "once per session".
let sessionStartHandled = false;

export default class Os7ShellExtension extends Extension {
    enable() {
        if (sessionStartHandled)
            return;
        sessionStartHandled = true;

        const overview = Main.overview;
        if (!overview.visible)
            return;
        // overview.js's own state, private: the public getters read the same
        // during the start-up animation as after it. Hook 0090 checks the
        // installed Shell still has it; without it, leave the overview open -
        // the #174 outcome, which costs a click, not the desktop.
        if (overview._shownState === 'SHOWN') {
            overview.hide();
            return;
        }
        if (overview._shownState !== 'SHOWING')
            return;

        this._shownId = overview.connect('shown', () => {
            this._standDown();
            // Out of the signal: 'shown' is emitted from inside the
            // overview's own state change.
            this._idleId = GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
                this._idleId = 0;
                overview.hide();
                return GLib.SOURCE_REMOVE;
            });
        });
        this._hidingId = overview.connect('hiding', () => this._standDown());
    }

    _standDown() {
        if (this._shownId)
            Main.overview.disconnect(this._shownId);
        if (this._hidingId)
            Main.overview.disconnect(this._hidingId);
        this._shownId = this._hidingId = 0;
    }

    disable() {
        this._standDown();
        if (this._idleId)
            GLib.source_remove(this._idleId);
        this._idleId = 0;
    }
}
