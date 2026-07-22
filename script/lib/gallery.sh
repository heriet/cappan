#!/usr/bin/env bash
# Shared helpers for script/generate-gallery-*.sh. Meant to be `source`d, not
# run directly, after the caller has already done `set -euo pipefail` and
# `cd "$(dirname "$0")/.."` (repo root -- required so `docker compose` finds
# compose.yaml, and so the re-exec'd path below resolves the same way inside
# the container).

# Re-execs the calling script inside the `dev` container exactly once, so a
# whole gallery's worth of images share a single container lifetime (and a
# single `zig build`) instead of starting a fresh container per image, as the
# old per-image `docker compose run --rm dev zig build run -- ...` did.
# Must be called with "$0" "$@" from the top-level script, before it does
# anything else that assumes it's already inside the container.
#
# The caller has already cd'd to repo root, so the script is re-exec'd inside
# the container by its repo-relative path `script/<basename>` (the repo is
# mounted at the container's working_dir). Passing the host "$0" verbatim
# would only resolve when the script was invoked from repo root by a
# repo-relative path; deriving it here works regardless of the host cwd/path.
gallery_reexec_in_container_once() {
    if [ -z "${GALLERY_IN_CONTAINER:-}" ]; then
        local script_path="script/$(basename "$1")"
        shift
        exec docker compose run --rm -e GALLERY_IN_CONTAINER=1 dev bash "$script_path" "$@"
    fi
}

gallery_build() {
    echo "Building cappan..."
    zig build
}

# $1 = output PNG name (without extension); remaining args are passed through
# to `cappan animate`. Expects FONT/TEXT/SIZE/FRAMES/FPS/HOLD/OUT to already
# be set by the caller.
gallery_animate() {
    local name="$1"
    shift
    echo "Generating $name..."
    zig-out/bin/cappan animate \
        --font "$FONT" --text "$TEXT" --size "$SIZE" \
        --frames "$FRAMES" --fps "$FPS" --hold "$HOLD" \
        "$@" \
        --output "$OUT/$name.png"
}

# $1 = output PNG name (without extension); remaining args are passed through
# to `cappan render`. Expects FONT/TEXT/SIZE/OUT to already be set by the caller.
gallery_render() {
    local name="$1"
    shift
    echo "Generating $name..."
    zig-out/bin/cappan render \
        --font "$FONT" --text "$TEXT" --size "$SIZE" \
        "$@" \
        --output "$OUT/$name.png"
}
