#!/bin/sh
# =============================================================================
# Spike S1, guest side. Runs inside the live session, off the payload volume.
#
#   sh /mnt/s1-look.sh free              take tty1 away from getty and show it
#   sh /mnt/s1-look.sh font [8x16|16x32] load the OS/7 console font on tty1
#   sh /mnt/s1-look.sh fillbg <n>        paint every cell with background index n
#   sh /mnt/s1-look.sh palette <file>    apply a .vtrgb at runtime
#   sh /mnt/s1-look.sh defclear          erase with the DEFAULT attribute
#   sh /mnt/s1-look.sh whopalette        where the live palette came from
#   sh /mnt/s1-look.sh paint <screen>    paint one §3.1 mockup on tty1
#   sh /mnt/s1-look.sh keys <n>          read n keypresses from tty1, in the
#                                        background, log to /tmp/keys.log
#   sh /mnt/s1-look.sh text              dump tty1's CHARACTER CELLS via /dev/vcs
#
#   sh /mnt/s1-look.sh setcolor <v>      \ not called by the harness; together
#   sh /mnt/s1-look.sh reset             / they reproduce the vt.color finding
#
# Every command ends by echoing a marker, because the harness drives this over a
# serial console and BUILD-NOTES #16 is unambiguous: never conclude a step ran
# because the next prompt appeared.
#
# It exists so that the lines the harness types stay short. Typing is the
# fragile half of serial-console driving; a 90-character command is 90 chances.
# =============================================================================
set -eu

HERE=/mnt
CMD="${1:-}"

case "${CMD}" in
ready)
	# Proof that the volume is mounted and readable, printed from a file so the
	# harness cannot mistake the shell's echo of the command for the answer
	# (BUILD-NOTES #16). Names what is actually there, not just that something is.
	printf 'S1-READY font=%s bin=%s\n' \
		"$(ls "${HERE}/fonts" | tr '\n' ' ')" \
		"$(test -x "${HERE}/os7-s1" && echo yes || echo MISSING)"
	;;

free)
	# getty@tty1 is what SETUP-PLAN §7 says gets masked when os7-setup runs, so
	# this is the production arrangement rather than a test affordance. Stopped
	# rather than masked: the live medium's /etc is an overlay and a mask would
	# outlive the phase for no benefit.
	systemctl stop getty@tty1.service 2>/dev/null || true
	chvt 1
	# The cursor is a block on an empty VT and lands in every screendump.
	printf '\033[?25l' > /dev/tty1
	echo "S1-FREE-OK"
	;;

font)
	SIZE="${2:-16x32}"
	# Uncompressed, because the payload volume mangles two-dot names
	# (see build_payload in run-s1.py).
	setfont -C /dev/tty1 "${HERE}/fonts/os7-fixedsys-${SIZE}.psf"
	# showconsolefont reports what the VT actually holds, not what setfont was
	# asked for - the difference is the whole point of checking.
	N="$(showconsolefont -i 2>/dev/null | head -n1 || echo '?')"
	echo "S1-FONT-OK ${SIZE} (${N})"
	;;


fillbg)
	# Paint every cell with an explicit background index. Unlike `clear`, this
	# does not depend on the VT's default attribute - so the two together
	# separate "the palette is wrong" from "the default attribute is wrong".
	printf '\033[4%sm\033[2J\033[H' "${2}" > /dev/tty1
	echo "S1-FILLBG-OK ${2}"
	;;

defclear)
	# SGR 0 puts the VT back on its DEFAULT attribute (the kernel's
	# default_attr(), i.e. vc_def_color, i.e. whatever vt.color set), and 2J then
	# erases with it. This is the only honest way to read the default attribute
	# back: RIS turned out not to repaint the framebuffer at all, so a screendump
	# after RIS measures the previous paint and nothing else.
	printf '\033[0m\033[2J\033[H' > /dev/tty1
	echo "S1-DEFCLEAR-OK"
	;;

vtcolor)
	printf 'vt.color=%s (0x%x) as the kernel holds it\n' \
		"$(cat /sys/module/vt/parameters/color)" \
		"$(cat /sys/module/vt/parameters/color)"
	echo "S1-VTCOLOR-OK"
	;;

setcolor)
	# /sys/module/vt/parameters/color is writable, so the whole vt.color value
	# space can be swept in one boot instead of one boot per value.
	#
	# Kept although run-s1.py does not call it, together with `reset` below.
	# The two of them are how "vt.color has no observable effect" was
	# established - set a value, RIS so the kernel re-applies it, fill the
	# screen with something else, then erase with the default attribute and
	# look. SESSION-S1-LOOK.md quotes four values; this is how to get a fifth.
	printf '%s' "${2}" > /sys/module/vt/parameters/color
	echo "S1-SETCOLOR-OK $(cat /sys/module/vt/parameters/color)"
	;;

reset)
	# RIS. The kernel re-applies vc_def_color, i.e. exactly what vt.color set.
	printf '\033c\033[?25l' > /dev/tty1
	echo "S1-RESET-OK"
	;;


whopalette)
	# Where the live palette came from. Three facts, printed together because
	# only together do they mean anything: what the kernel was told, what the
	# console is actually using now, and what is on disk to explain a difference.
	printf 'cmdline-red=%s\n' "$(sed -n 's/.*vt.default_red=\([0-9,]*\).*/\1/p' /proc/cmdline | cut -c1-40)"
	printf 'live-red=%s\n'    "$(cut -c1-40 /sys/module/vt/parameters/default_red)"
	printf 'vtrgb=%s -> %s\n' "$(readlink -f /etc/vtrgb)" "$(head -n1 /etc/vtrgb | cut -c1-40)"
	printf 'service=%s\n'     "$(systemctl is-active setvtrgb.service 2>&1)"
	echo "S1-WHO-OK"
	;;

palette)
	/usr/sbin/setvtrgb "${2}"
	echo "S1-PALETTE-OK ${2}"
	;;

paint)
	"${HERE}/os7-s1" paint "${2}" > /dev/tty1
	echo "S1-PAINT-OK ${2}"
	;;

probe)
	"${HERE}/os7-s1" probe > /dev/tty1
	echo "S1-PROBE-OK"
	;;

keys)
	# stdin and stdout on tty1 - the program reads the keyboard that VT owns and
	# paints where the screen is - while stderr stays on the SERIAL line, which
	# is how the evidence reaches the harness live.
	#
	# Foreground, deliberately. Backgrounding it first looked obvious (the
	# harness has to press keys while it runs) and cost a debugging cycle: the
	# harness drives QEMU, not this shell, so nothing here needs to stay
	# responsive - and `cmd &` in a non-interactive shell brings POSIX's
	# stdin-from-/dev/null rule and a `wait` that has to be got right for no
	# benefit at all. Running it in front means the prompt coming back IS the
	# completion signal.
	"${HERE}/os7-s1" keys "${2}" < /dev/tty1 > /dev/tty1
	echo "S1-KEYS-OK"
	;;

text)
	# kbd's screendump reads /dev/vcs1, i.e. the VT's character cells. That is a
	# different path from QEMU's framebuffer grab all the way down, so the two
	# agreeing means the frame is what the program meant to draw and not an
	# artefact of either reader. BUILD-NOTES: a diagnostic must not depend on
	# the subsystem it is diagnosing.
	screendump 1 | sed -n "${2:-1,10}p" | sed 's/[[:space:]]*$//'
	echo "S1-TEXT-OK"
	;;

*)
	echo "S1-USAGE: free|font|clear|palette|paint|probe|keys|text" >&2
	exit 2
	;;
esac
