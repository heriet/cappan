DOCKER_RUN = docker compose run --rm dev
ZENSICAL_RUN = docker compose run --rm doc
DOCS_PORT ?= 8000

.PHONY: build test run fmt clean shell fetch-asset generate-subset setup build-docs serve-docs generate-gallery generate-gallery-incremental generate-gallery-stroke-paint build-wasm release-windows release-linux test-colr-v1

setup: fetch-asset generate-subset

build: setup
	$(DOCKER_RUN) zig build

build-wasm:
	$(DOCKER_RUN) zig build wasm
	mkdir -p docs/demo
	cp cappan_wasm/web/index.html docs/demo/

test: setup
	$(DOCKER_RUN) zig build test

run:
	$(DOCKER_RUN) zig build run -- $(ARGS)

fmt:
	$(DOCKER_RUN) zig fmt cappan_core/src/ cappan_cli/src/

clean:
	rm -rf zig-out .zig-cache

shell:
	$(DOCKER_RUN) /bin/bash

fetch-asset:
	$(DOCKER_RUN) bash script/fetch-asset.sh

generate-subset:
	$(DOCKER_RUN) bash script/generate-subset.sh

generate-gallery: generate-gallery-incremental generate-gallery-stroke-paint

generate-gallery-incremental:
	bash script/generate-gallery-incremental.sh

generate-gallery-stroke-paint:
	bash script/generate-gallery-stroke-paint.sh

build-docs:
	$(ZENSICAL_RUN) build
	$(MAKE) build-wasm

release-windows:
	$(DOCKER_RUN) zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe

release-linux:
	$(DOCKER_RUN) zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe

test-colr-v1:
	@if [ ! -f .font/TestCOLRv1.ttf ]; then \
		echo "TestCOLRv1.ttf not found, running fetch-asset.sh..."; \
		$(DOCKER_RUN) bash script/fetch-asset.sh; \
	fi
	$(DOCKER_RUN) zig build
	$(DOCKER_RUN) zig-out/bin/cappan render \
		--font .font/TestCOLRv1.ttf \
		--text "A" \
		--size 32 \
		--output /tmp/test_colr_v1_basic.png
	$(DOCKER_RUN) zig-out/bin/cappan render \
		--font .font/test_glyphs-glyf_colr_1.ttf \
		--text "A" \
		--size 32 \
		--output /tmp/test_colr_v1_glyphs.png
	@echo "test-colr-v1: PASS (no crash)"

serve-docs:
	python3 -m http.server $(DOCS_PORT) -d docs
