# =============================================================================
# OS/7 — build entrypoints
#
#   *** STUB — no target here has produced an OS/7 ISO. ***
#
# The container/invocation shape is HARVESTED FROM A PRIOR BUILD SESSION
# (2026-06-24). See docs/BUILD-NOTES.md.
# =============================================================================

IMAGE := os7-build
OUT   := $(CURDIR)/out

# Host architecture decides how amd64 gets built.
#   x86_64 host (Intel/AMD Mac, x64 Windows, x86_64 Linux) -> native, use Docker.
#   arm64 host  (Apple Silicon)                            -> Docker's amd64
#     emulation cannot unpack a Debian rootfs (ENOSYS in GNU tar, still broken
#     on Docker 29.7.2 - docs/BUILD-NOTES.md #12). Use the QEMU x86 VM instead.
HOST_ARCH := $(shell uname -m)

# Privileged: live-build needs chroot, bind mounts and loop devices (README:
# "The build container runs privileged").
#
# HARVESTED FIX 8: no -it here. Batch builds run head-less in CI and -it fails
# there with "the input device is not a TTY". The shell-* targets add it back.
#
# $(1) = arch (amd64|arm64), $(2) = extra docker flags placed BEFORE the image.
define DOCKER_RUN
docker run --rm --platform linux/$(1) \
  --privileged \
  -v $(CURDIR):/work \
  -v $(OUT):/work/out \
  $(2) $(IMAGE):$(1)
endef

# The three SOURCE FACTS - commit count, commit, dirty - asked of git ON THE HOST
# and handed to build.sh as environment (scripts/os7-source-facts.sh). build.sh
# accepts them and remains the only place that composes a version STRING, which
# is what docs/RELEASE-AND-UPDATE-PLAN.md §3 requires: this hands over facts, it
# does not build a number.
#
# The container cannot ask git for itself. In a git WORKTREE, `.git` is a FILE
# holding an absolute path to <main>/.git/worktrees/<name> - a path that is NOT
# inside the bind mount - so git at /work answers "not a git repository" and the
# ISO comes out as x.y.z.0, commit "unknown", reproducible=false, whatever the
# worktree actually contains. (docs/BUILD-NOTES.md #43.)
#
# Recursively expanded (=, not :=) deliberately: `make help` and `make clean`
# never run git, and each build target expands it exactly once. Empty when git
# cannot answer at all - build.sh decides what that means, and it is the one
# place that decision lives.
SOURCE_FACTS = $(addprefix -e ,$(shell $(CURDIR)/scripts/os7-source-facts.sh $(CURDIR)))

.PHONY: help image-amd64 image-arm64 build-amd64 build-arm64 check-amd64-host \
        build-amd64-vm build-amd64-vm-reset \
        lb-config shell-amd64 shell-arm64 clean

help:
	@echo "OS/7 build targets (STUBS - none has produced an OS/7 ISO yet):"
	@echo "  make build-amd64  Build the x86_64 ISO -> ./out/os7-amd64.iso"
	@echo "                    (x86_64 hosts only; on Apple Silicon use build-amd64-vm)"
	@echo "  make build-amd64-vm  Build the x86_64 ISO in a QEMU x86 VM (ARM hosts; slow)"
	@echo "  make build-arm64  Build the arm64 ISO  -> ./out/os7-arm64.iso"
	@echo "  make lb-config    Run 'lb config' only (validates auto/config)"
	@echo "  make shell-amd64  Interactive shell in the amd64 build container"
	@echo "  make shell-arm64  Interactive shell in the arm64 build container"
	@echo "  make clean        Remove build artifacts"
	@echo ""
	@echo "NOTE (Apple Silicon): build-amd64 runs under Docker Desktop's x86"
	@echo "emulation and is slow. CI uses native runners per arch - see"
	@echo ".github/workflows/build-iso.yml."

# --provenance=false: keeps BuildKit from adding an attestation manifest, which
# turns the single-arch image into an index and confuses --platform pinning.
image-amd64:
	docker build --provenance=false --platform linux/amd64 -t $(IMAGE):amd64 .

image-arm64:
	docker build --provenance=false --platform linux/arm64 -t $(IMAGE):arm64 .

# Refuse early on a non-x86_64 host: the emulated build fails partway through
# debootstrap, and this check must come BEFORE image-amd64 so we do not spend a
# Docker build reaching a known failure.
# Set OS7_FORCE_EMULATED_AMD64=1 to try anyway.
check-amd64-host:
	@if [ "$(HOST_ARCH)" != "x86_64" ] && [ -z "$$OS7_FORCE_EMULATED_AMD64" ]; then \
		echo ""; \
		echo "  Host is $(HOST_ARCH), not x86_64."; \
		echo "  Docker's amd64 emulation cannot unpack a Debian rootfs here:"; \
		echo "    tar: Cannot mkdir: Function not implemented   (ENOSYS)"; \
		echo "  See docs/BUILD-NOTES.md #12."; \
		echo ""; \
		echo "  Use:  make build-amd64-vm     (full QEMU x86 VM; slow but works)"; \
		echo "  Or run 'make build-amd64' on an x86_64 machine, where it is native."; \
		echo "  Override:  OS7_FORCE_EMULATED_AMD64=1 make build-amd64"; \
		echo ""; \
		exit 1; \
	fi

# On an x86_64 host this is native and fast - the right way to build amd64.
build-amd64: check-amd64-host image-amd64
	mkdir -p $(OUT)
	$(call DOCKER_RUN,amd64,$(SOURCE_FACTS)) /work/build/build.sh amd64

# amd64 ISO via full x86 system emulation. Needed only on ARM hosts.
# Not Docker: QEMU emulates a whole x86 machine, so no syscall translation and
# no ENOSYS. Takes hours under TCG - a correctness escape hatch, not a dev loop.
build-amd64-vm:
	./scripts/build-amd64-vm.sh

build-amd64-vm-reset:
	./scripts/build-amd64-vm.sh --reset

build-arm64: image-arm64
	mkdir -p $(OUT)
	$(call DOCKER_RUN,arm64,$(SOURCE_FACTS)) /work/build/build.sh arm64

# Config-only smoke test: stages the tree and runs `lb config`, no `lb build`.
#
# The pin file and OS7_VERSION are staged here too because auto/config refuses to
# run without them - deliberately, so that no path can reach the archive
# unpinned. The version here is a placeholder: this target validates the
# configuration, it does not produce a medium anyone could quote it from.
lb-config: image-amd64
	$(call DOCKER_RUN,amd64,) bash -c 'set -e; \
	  rm -rf /os7-build && mkdir -p /os7-build/config; \
	  cp -a /work/build/config/auto /os7-build/auto; \
	  cp -a /work/build/config/os7-release.conf /os7-build/auto/os7-release.conf; \
	  cd /os7-build && OS7_ARCH=amd64 OS7_VERSION=0.0.0.0 lb config && echo "lb config OK"'

shell-amd64: image-amd64
	$(call DOCKER_RUN,amd64,-it) bash

shell-arm64: image-arm64
	$(call DOCKER_RUN,arm64,-it) bash

clean:
	-$(call DOCKER_RUN,amd64,) /work/build/build.sh clean
	rm -rf $(OUT)
