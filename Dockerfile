# =============================================================================
# OS/7 — build container
#
#   *** STUB — UNVALIDATED ***
#
# Never successfully built or run. Package list is a first guess at what
# live-build needs to bootstrap an Ubuntu 26.04 "resolute" live system.
#
# Must be run PRIVILEGED: live-build mounts /proc, /sys and loop devices
# inside the chroot it builds. See the Makefile's DOCKER_RUN.
# =============================================================================

# STUB: assumes an ubuntu:26.04 image exists and that its live-build/debootstrap
# know the "resolute" suite. If bootstrap fails with "unknown suite", this base
# image (or debootstrap's script set) is the first thing to check.
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LC_ALL=C.UTF-8

# STUB: unpinned, unverified. Nothing here is known to be sufficient — or
# necessary — yet.
RUN apt-get update && apt-get install --no-install-recommends -y \
	live-build \
	debootstrap \
	squashfs-tools \
	xorriso \
	isolinux \
	syslinux-common \
	grub-pc-bin \
	grub-efi-amd64-bin \
	grub-efi-arm64-bin \
	mtools \
	dosfstools \
	ca-certificates \
	curl \
	git \
	make \
	rsync \
	sudo \
	&& rm -rf /var/lib/apt/lists/*

# The repo is bind-mounted here by the Makefile; live-build runs in build/.
WORKDIR /os7/build

CMD ["/bin/bash"]
