# syntax=docker/dockerfile:1
# This file only wires the layers together. Each layer is a folder in layers/ with an install.sh.
# A step runs again when a file of its layer changed, or when build.sh passes a new REFRESH_<LAYER> value
# (build.sh --update). A step that runs again takes the newest versions, and the steps after it run again too.
# Each step mounts only layers/lib.sh and its own layer folder, so an edit in one layer leaves the others alone.
FROM docker.io/docker/sbx-kit-claude:latest AS claude-kit

# Build-only stage: its tools (Rust, the tree-sitter CLI) do not ship. The two steps write their result to /out.
# The plugin lock comes in as a secret mount, because a secret is not part of a step's cache key: a different lock
# alone does not run the plugins step again. The lock is not a secret.
FROM claude-kit AS nvim-build
USER root
ARG REFRESH_NVIM
RUN --mount=type=bind,source=layers/lib.sh,target=/layers/lib.sh \
    --mount=type=bind,source=layers/nvim/build-tools.sh,target=/layers/nvim/build-tools.sh \
    /layers/nvim/build-tools.sh
RUN --mount=type=bind,source=layers/lib.sh,target=/layers/lib.sh \
    --mount=type=bind,source=layers/nvim,target=/layers/nvim \
    --mount=type=secret,id=lazy-lock,target=/run/lazy-lock.json \
    /layers/nvim/build.sh

FROM claude-kit
ENV SBX_STACK=/usr/local/share/sbx-stack
USER root
ARG REFRESH_TOOLS
RUN --mount=type=bind,source=layers/lib.sh,target=/layers/lib.sh \
    --mount=type=bind,source=layers/tools,target=/layers/tools \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    /layers/tools/install.sh
ARG REFRESH_ZSH
RUN --mount=type=bind,source=layers/lib.sh,target=/layers/lib.sh \
    --mount=type=bind,source=layers/zsh,target=/layers/zsh \
    /layers/zsh/install.sh
ARG REFRESH_GIT
ARG GIT_USER_NAME=
ARG GIT_USER_EMAIL=
RUN --mount=type=bind,source=layers/lib.sh,target=/layers/lib.sh \
    --mount=type=bind,source=layers/git,target=/layers/git \
    /layers/git/install.sh
ARG REFRESH_WORKTRUNK
RUN --mount=type=bind,source=layers/lib.sh,target=/layers/lib.sh \
    --mount=type=bind,source=layers/worktrunk,target=/layers/worktrunk \
    /layers/worktrunk/install.sh
ARG REFRESH_YAZI
RUN --mount=type=bind,source=layers/lib.sh,target=/layers/lib.sh \
    --mount=type=bind,source=layers/yazi,target=/layers/yazi \
    /layers/yazi/install.sh
ARG REFRESH_CLAUDE
RUN --mount=type=bind,source=layers/lib.sh,target=/layers/lib.sh \
    --mount=type=bind,source=layers/claude,target=/layers/claude \
    /layers/claude/install.sh
RUN --mount=type=bind,source=layers/nvim,target=/layers/nvim \
    --mount=type=bind,from=nvim-build,source=/out,target=/out \
    /layers/nvim/install.sh

ARG VERSION
ARG REVISION
RUN printf '%s %s\n' "$VERSION" "$REVISION" > "$SBX_STACK/VERSION"
USER agent
