DOCKER_RUN = docker compose run --rm dev
ZENSICAL_RUN = docker compose run --rm doc
DOCS_PORT ?= 8000

.PHONY: build test run fmt clean shell fetch-asset generate-subset setup build-docs serve-docs generate-gallery generate-gallery-incremental generate-gallery-stroke-paint build-wasm release-windows release-linux test-colr-v1 test-colr-v1-variable test-vertical test-arabic test-sdf

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

test-colr-v1-variable:
	@if [ ! -f .font/test_glyphs-glyf_colr_1_variable.ttf ]; then \
		echo "variable COLR font not found, running fetch-asset.sh..."; \
		$(DOCKER_RUN) bash script/fetch-asset.sh; \
	fi
	$(DOCKER_RUN) zig build
	$(DOCKER_RUN) zig-out/bin/cappan render \
		--font .font/test_glyphs-glyf_colr_1_variable.ttf \
		--text "$$(printf '\363\260\204\200\363\260\210\200')" \
		--size 128 \
		--variation "SWPS=0,ROTA=0,APH1=0,GRX0=0,TLDX=0" \
		--output /tmp/colr_var_default.png
	$(DOCKER_RUN) zig-out/bin/cappan render \
		--font .font/test_glyphs-glyf_colr_1_variable.ttf \
		--text "$$(printf '\363\260\204\200\363\260\210\200')" \
		--size 128 \
		--variation "SWPS=-45,ROTA=90,APH1=-0.7,GRX0=500,TLDX=100" \
		--output /tmp/colr_var_moved.png
	@if cmp -s /tmp/colr_var_default.png /tmp/colr_var_moved.png; then \
		echo "test-colr-v1-variable: FAIL (output did not change)"; exit 1; \
	else echo "test-colr-v1-variable: PASS (output changed with axis)"; fi

test-vertical:
	@if [ ! -f .font/NotoSansJP-Regular.otf ]; then \
		echo "NotoSansJP-Regular.otf not found, running fetch-asset.sh..."; \
		$(DOCKER_RUN) bash script/fetch-asset.sh; \
	fi
	$(DOCKER_RUN) zig build
	$(DOCKER_RUN) zig-out/bin/cappan render \
		--font .font/NotoSansJP-Regular.otf \
		--text "$$(printf '縦書きの\nテスト')" \
		--size 32 \
		--vertical \
		--output /tmp/test_vertical.png
	@echo "test-vertical: PASS (no crash)"

# The printf octal escapes encode "العربية" (UTF-8). POSIX sh printf does not
# support \x hex escapes, so octal is required here.
test-arabic:
	@if [ ! -f .font/NotoSansArabic-Regular.ttf ]; then \
		echo "NotoSansArabic-Regular.ttf not found, running fetch-asset.sh..."; \
		$(DOCKER_RUN) bash script/fetch-asset.sh; \
	fi
	$(DOCKER_RUN) zig build
	$(DOCKER_RUN) zig-out/bin/cappan render \
		--font .font/NotoSansArabic-Regular.ttf \
		--text "$$(printf '\330\247\331\204\330\271\330\261\330\250\331\212\330\251')" \
		--size 32 \
		--output /tmp/test_arabic_h.png
	$(DOCKER_RUN) zig-out/bin/cappan render \
		--font .font/NotoSansArabic-Regular.ttf \
		--text "$$(printf '\330\247\331\204\330\271\330\261\330\250\331\212\330\251')" \
		--size 32 \
		--vertical \
		--output /tmp/test_arabic_v.png
	@echo "test-arabic: PASS (no crash)"

test-sdf:
	$(DOCKER_RUN) zig build
	$(DOCKER_RUN) zig-out/bin/cappan render \
		--font .font/DejaVuSans.ttf --text "SDF test" --size 48 \
		--sdf --output /tmp/test_sdf.png
	$(DOCKER_RUN) zig-out/bin/cappan atlas \
		--font .font/DejaVuSans.ttf --text "ABCDEFabcdef012" --size 64 \
		--output /tmp/test_sdf_atlas.png --metrics /tmp/test_sdf_atlas.json
	$(DOCKER_RUN) zig-out/bin/cappan render \
		--font .font/DejaVuSans.ttf --text "MSDF test" --size 48 \
		--msdf --output /tmp/test_msdf.png
	$(DOCKER_RUN) zig-out/bin/cappan atlas \
		--font .font/DejaVuSans.ttf --text "ABCDEFabcdef012" --size 64 \
		--msdf --output /tmp/test_msdf_atlas.png --metrics /tmp/test_msdf_atlas.json
	@echo "test-sdf: PASS (no crash)"

serve-docs:
	python3 -m http.server $(DOCS_PORT) -d docs
