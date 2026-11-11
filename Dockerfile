# syntax=docker/dockerfile:1
# This file only wires the layers together. Each layer is a folder in layers/ with an install.sh.
# A new REFRESH value (build.sh passes the build time) runs every step again, so each build installs the newest
# version of everything.
FROM docker.io/docker/sbx-kit-claude:latest AS claude-kit

# Build-only stage: its tools (Rust, the tree-sitter CLI) do not ship. build.sh writes its result to /out.
FROM claude-kit AS nvim-build
USER root
ARG REFRESH
RUN --mount=type=bind,source=layers,target=/layers /layers/nvim/build.sh

FROM claude-kit
ENV SBX_STACK=/usr/local/share/sbx-stack
USER root
ARG REFRESH
RUN --mount=type=bind,source=layers,target=/layers \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    /layers/tools/install.sh
RUN --mount=type=bind,source=layers,target=/layers /layers/zsh/install.sh
ARG GIT_USER_NAME=
ARG GIT_USER_EMAIL=
RUN --mount=type=bind,source=layers,target=/layers /layers/git/install.sh
RUN --mount=type=bind,source=layers,target=/layers /layers/worktrunk/install.sh
RUN --mount=type=bind,source=layers,target=/layers /layers/yazi/install.sh
RUN --mount=type=bind,source=layers,target=/layers /layers/claude/install.sh
RUN --mount=type=bind,source=layers,target=/layers \
    --mount=type=bind,from=nvim-build,source=/out,target=/out \
    /layers/nvim/install.sh

ARG VERSION
ARG REVISION
RUN printf '%s %s\n' "$VERSION" "$REVISION" > "$SBX_STACK/VERSION"
USER agent
