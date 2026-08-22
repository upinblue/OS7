# =============================================================================
# OS/7 — build entrypoints
#
#   *** STUB — UNVALIDATED ***
#
# No target below has ever completed successfully. `make build-amd64` is
# expected to fail; iterating against its real error output is the point.
# =============================================================================

IMAGE       ?= os7-build
BUILD_DIR   ?= build

# live-build needs real mounts and loop devices -> privileged, per README
# ("The build container runs privileged").
DOCKER_RUN = docker run --rm -it --privileged \
	-v "$(CURDIR)":/os7 \
	-w /os7/$(BUILD_DIR)

.PHONY: help image shell lb-config build-amd64 build-arm64 clean distclean

help:
	@echo "OS/7 build targets (ALL STUBS — none verified to work yet):"
	@echo "  make image        Build the $(IMAGE) container from ./Dockerfile"
	@echo "  make lb-config    Run 'lb config' in the container (validates auto/config)"
	@echo "  make build-amd64  Build the x86_64 ISO"
	@echo "  make build-arm64  Build the arm64 ISO"
	@echo "  make shell        Interactive shell in the build container"
	@echo "  make clean        lb clean"
	@echo "  make distclean    lb clean --purge + remove generated config"

image:
	docker build -t $(IMAGE) .

# NOTE (Apple Silicon): the host here is arm64, so a native 'docker build' /
# 'docker run' produces an arm64 container. Building the amd64 ISO locally
# therefore runs under Docker Desktop's x86 emulation and will be slow.
# CI avoids this entirely by using native runners per architecture — see
# .github/workflows/build-iso.yml.
image-amd64:
	docker build --platform linux/amd64 -t $(IMAGE):amd64 .

image-arm64:
	docker build --platform linux/arm64 -t $(IMAGE):arm64 .

lb-config: image
	$(DOCKER_RUN) $(IMAGE) lb config

shell: image
	$(DOCKER_RUN) $(IMAGE) /bin/bash

build-amd64: image-amd64
	$(DOCKER_RUN) --platform linux/amd64 -e OS7_ARCH=amd64 $(IMAGE):amd64 \
		/bin/bash -c "lb config && lb build"

build-arm64: image-arm64
	$(DOCKER_RUN) --platform linux/arm64 -e OS7_ARCH=arm64 $(IMAGE):arm64 \
		/bin/bash -c "lb config && lb build"

clean:
	$(DOCKER_RUN) $(IMAGE) lb clean

distclean:
	$(DOCKER_RUN) $(IMAGE) lb clean --purge
