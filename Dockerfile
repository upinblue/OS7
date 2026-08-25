# =============================================================================
# OS/7 — build container
#
#   *** STUB — the OS/7 content is not written yet, but the build-environment
#   *** fixes below are HARVESTED FROM A PRIOR BUILD SESSION (2026-06-24) that
#   *** did get an arm64 ISO out of live-build. Don't "simplify" them back.
#   *** See docs/BUILD-NOTES.md for why each one is here.
#
# Must run PRIVILEGED: live-build needs chroot, bind mounts and loop devices.
# =============================================================================

# 26.04 host for a 26.04 target, so debootstrap is guaranteed to know the
# "resolute" suite. The prior session used ubuntu:24.04 successfully; if this
# base causes trouble, that is the proven fallback (but check for
# /usr/share/debootstrap/scripts/resolute before blaming anything else).
FROM ubuntu:26.04

# HARVESTED FIX 1: the build container must be architecture-MATCHED to the
# target ISO. GRUB bootloader binaries are arch-specific and are not
# cross-available from a single archive: amd64 has grub-pc-bin +
# grub-efi-amd64-bin, arm64 has grub-efi-arm64-bin. Installing both in one
# image can never resolve. TARGETARCH is populated by BuildKit from the
# --platform the Makefile passes.
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive
ENV LC_ALL=C.UTF-8

RUN apt-get update && apt-get install --no-install-recommends -y \
	live-build \
	debootstrap \
	squashfs-tools \
	xorriso \
	isolinux \
	syslinux-common \
	mtools \
	dosfstools \
	ca-certificates \
	curl \
	gnupg \
	git \
	make \
	rsync \
	sudo \
	`# HARVESTED FIX 2: unmkinitramfs needs these to decompress Ubuntu's` \
	`# (zstd-compressed) initrd during lb_binary_disk. Without them the` \
	`# binary stage fails.` \
	zstd \
	xz-utils \
	lz4 \
	`# Console font toolchain (SETUP-PLAN 2.5). FSEX302.ttf is a TTF and the` \
	`# Linux console reads PSF only, so the conversion is a BUILD step:` \
	`# otf2bdf rasterises the outlines at 16 px, bdf2psf packs the subset.` \
	`# It lives here and never in the image - see build/lib/build-console-font.sh.` \
	otf2bdf \
	bdf2psf \
	`# The INSTALLED console's font is Cascadia Mono (SETUP-PLAN 2.8, D15) and` \
	`# needs a second route: otf2bdf scales both axes together, so from Cascadia` \
	`# it reaches 8x15 or 9x16 and never 8x16 (BUILD-NOTES #52).` \
	`# build/lib/cellfont.py drives libfreetype directly to hit the cell exactly.` \
	`#` \
	`# NOTE THAT libfreetype IS PART OF WHAT THE IMAGE LOOKS LIKE. It is a` \
	`# container package, not an archive-pinned one, and 41 of 409 glyphs differ` \
	`# between 2.13.2 and 2.14.2 from the same TTF. That is why the built PSFs` \
	`# are hashed against OS7_CASCADIA_PSF_SHA256_* - rebuilding this container` \
	`# can change the console with no version number moving. BUILD-NOTES #58.` \
	python3-freetype \
	`# os7-setup is NativeAOT C# (SETUP-PLAN 6.1). The exact list spike S2` \
	`# established: the SDK, and the linker toolchain ILCompiler shells out to.` \
	`# docs/SESSION-S2-NATIVEAOT.md.` \
	dotnet-sdk-10.0 \
	clang \
	zlib1g-dev \
	libc6-dev \
	binutils \
	&& if [ "${TARGETARCH}" = "arm64" ]; then \
		apt-get install --no-install-recommends -y grub-efi-arm64-bin; \
	else \
		apt-get install --no-install-recommends -y grub-pc-bin grub-efi-amd64-bin; \
	fi \
	&& rm -rf /var/lib/apt/lists/*

# The repo is bind-mounted here at run time (see Makefile). NOTE: the build
# itself does NOT happen here — build.sh stages into a container-local dir.
# See HARVESTED FIX 3 in docs/BUILD-NOTES.md.
WORKDIR /work

CMD ["/bin/bash"]
