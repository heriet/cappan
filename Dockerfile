FROM debian:bookworm-slim

ARG ZIG_VERSION=0.16.0
ARG UID=1000
ARG GID=1000

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils unzip woff2 fonts-dejavu-core \
    python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

RUN curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt && ln -s /opt/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig \
    && ln -s /opt/zig-x86_64-linux-${ZIG_VERSION}/lib /usr/local/lib/zig

RUN pip3 install --break-system-packages fonttools

RUN groupadd -g ${GID} devuser || true \
    && useradd -m -u ${UID} -g ${GID} devuser

WORKDIR /workspace
USER devuser
