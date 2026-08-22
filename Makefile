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

.PHONY: help image-amd64 image-arm64 build-amd64 build-arm64 \
        lb-config shell-amd64 shell-arm64 clean

help:
	@echo "OS/7 build targets (STUBS - none has produced an OS/7 ISO yet):"
	@echo "  make build-amd64  Build the x86_64 ISO -> ./out/os7-amd64.iso"
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

build-amd64: image-amd64
	mkdir -p $(OUT)
	$(call DOCKER_RUN,amd64,) /work/build/build.sh amd64

build-arm64: image-arm64
	mkdir -p $(OUT)
	$(call DOCKER_RUN,arm64,) /work/build/build.sh arm64

# Config-only smoke test: stages the tree and runs `lb config`, no `lb build`.
lb-config: image-amd64
	$(call DOCKER_RUN,amd64,) bash -c 'set -e; \
	  rm -rf /os7-build && mkdir -p /os7-build/config; \
	  cp -a /work/build/config/auto /os7-build/auto; \
	  cd /os7-build && OS7_ARCH=amd64 lb config && echo "lb config OK"'

shell-amd64: image-amd64
	$(call DOCKER_RUN,amd64,-it) bash

shell-arm64: image-arm64
	$(call DOCKER_RUN,arm64,-it) bash

clean:
	-$(call DOCKER_RUN,amd64,) /work/build/build.sh clean
	rm -rf $(OUT)
