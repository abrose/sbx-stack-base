# syntax=docker/dockerfile:1
FROM docker.io/docker/sbx-kit-claude:2.1.314@sha256:5698d4430c206770c1243c7ac08a504133b0c31b2ae6ef002efb46653b156b76
LABEL sbx-stack.claude-kit=2.1.314

ARG OMZ_COMMIT=17a2b4c3a5855524ad4772a17ada0dc474e2fdf3
ARG FSH_COMMIT=3d574ccf48804b10dca52625df13da5edae7f553
ARG FZF_TAB_COMMIT=24105b15714bfec37989ed5c5b6e60f572253019

ENV SBX_STACK=/usr/local/share/sbx-stack
USER root

COPY apt-packages.txt /tmp/apt-packages.txt
RUN apt-get update \
 && xargs -a /tmp/apt-packages.txt env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/* /tmp/apt-packages.txt \
 && ln -sf /usr/bin/batcat /usr/local/bin/bat \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd

RUN set -e; \
    clone() { mkdir -p "$1"; git -C "$1" init -q; git -C "$1" fetch -q --depth 1 "$2" "$3"; git -C "$1" checkout -q FETCH_HEAD; rm -rf "$1/.git"; }; \
    clone "$SBX_STACK/oh-my-zsh" https://github.com/ohmyzsh/ohmyzsh.git "$OMZ_COMMIT"; \
    clone "$SBX_STACK/oh-my-zsh-custom/plugins/fast-syntax-highlighting" \
      https://github.com/zdharma-continuum/fast-syntax-highlighting.git "$FSH_COMMIT"; \
    clone "$SBX_STACK/oh-my-zsh-custom/plugins/fzf-tab" https://github.com/Aloxaf/fzf-tab.git "$FZF_TAB_COMMIT"

COPY files/zsh $SBX_STACK/zsh
COPY files/git $SBX_STACK/git
COPY files/claude $SBX_STACK/claude
COPY files/starship.toml $SBX_STACK/starship.toml
RUN printf '\nsource %s/zsh/zshrc\n' "$SBX_STACK" >> /etc/zsh/zshrc \
 && usermod -s /usr/bin/zsh agent \
 && install -o agent -g agent -m 644 /dev/null /home/agent/.zshrc \
 && install -D -m 644 "$SBX_STACK/claude/managed-settings.json" /etc/claude-code/managed-settings.json \
 && git config --system --add include.path "$SBX_STACK/git/aliases.gitconfig"

USER agent
RUN set -e; \
    c=/home/agent/.local/bin/claude; \
    "$c" plugin marketplace add anthropics/claude-plugins-official; \
    "$c" plugin marketplace add abrose/claude-plugins; \
    for p in adhd-friendly-simple-technical-english@abrose-plugins quota-statusline@abrose-plugins \
      hookify@claude-plugins-official superpowers@claude-plugins-official; do \
      "$c" plugin install "$p"; \
    done; \
    rm -rf /home/agent/.claude/.credentials.json /home/agent/.claude/sessions /home/agent/.claude/settings.json \
      /home/agent/.claude.json /home/agent/.claude.json.backup

USER root
ARG GIT_USER_NAME=
ARG GIT_USER_EMAIL=
RUN { [ -z "$GIT_USER_NAME" ] || git config --system user.name "$GIT_USER_NAME"; } \
 && { [ -z "$GIT_USER_EMAIL" ] || git config --system user.email "$GIT_USER_EMAIL"; }

ARG VERSION
ARG REVISION
RUN printf '%s %s\n' "$VERSION" "$REVISION" > "$SBX_STACK/VERSION"
USER agent
