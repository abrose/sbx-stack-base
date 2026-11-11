# syntax=docker/dockerfile:1
FROM docker.io/docker/sbx-kit-claude:2.1.314@sha256:5698d4430c206770c1243c7ac08a504133b0c31b2ae6ef002efb46653b156b76 AS claude-kit

# The stages up to the final one do not ship. They download each release file, check its sha256 and build.
# The apt lists stay in a build cache that all apt steps share: each download of the lists is 31 MB.
FROM claude-kit AS fetch
USER root
RUN --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xz-utils
COPY --chmod=755 <<'EOF' /usr/local/bin/fetch
#!/bin/sh
# fetch <file> <url> <sha256>: downloads the url to the file and fails when the sha256 differs.
set -e
curl -fsSLo "$1" "$2"
echo "$3  $1" | sha256sum -c -
EOF
WORKDIR /tmp/fetch

# /out ships in the final image; /build is for nvim-build only.
FROM fetch AS releases
ARG NVIM_VERSION=0.12.6
ARG NVIM_SHA256=8f1f64a0bdb97247034038c3823c6cbad5bdf9ecd5751b85494b71c3ee04c815
ARG YAZI_VERSION=26.9.1
ARG YAZI_SHA256=02807f08d6b589b65b7516a4e259d83f5995d7a23bb12b3a155141385b370b3a
ARG WT_VERSION=0.81.0
ARG WT_SHA256=7a334d2e64c577afd0247e2411eff673360ab1f18897564f2d2e5d5374fbd74b
ARG TREE_SITTER_VERSION=0.27.2
ARG TREE_SITTER_SHA256=34fcc5c4fa7bdd2058a2a45a03b6eb9a49b03a93b6d52ec750f99b1516d98d33
RUN set -e; \
    gh=https://github.com; \
    fetch nvim.tar.gz "$gh/neovim/neovim/releases/download/v$NVIM_VERSION/nvim-linux-arm64.tar.gz" "$NVIM_SHA256"; \
    fetch yazi.zip "$gh/sxyazi/yazi/releases/download/v$YAZI_VERSION/yazi-aarch64-unknown-linux-gnu.zip" \
      "$YAZI_SHA256"; \
    fetch wt.tar.xz \
      "$gh/max-sixty/worktrunk/releases/download/v$WT_VERSION/worktrunk-aarch64-unknown-linux-musl.tar.xz" "$WT_SHA256"; \
    fetch tree-sitter.gz \
      "$gh/tree-sitter/tree-sitter/releases/download/v$TREE_SITTER_VERSION/tree-sitter-linux-arm64.gz" \
      "$TREE_SITTER_SHA256"; \
    mkdir -p /out/opt/nvim /out/usr/local/bin /build/usr/local/bin; \
    tar -xzf nvim.tar.gz -C /out/opt/nvim --strip-components=1; \
    ln -s /opt/nvim/bin/nvim /out/usr/local/bin/nvim; \
    unzip -q yazi.zip; \
    install -m 755 yazi-aarch64-unknown-linux-gnu/yazi yazi-aarch64-unknown-linux-gnu/ya /out/usr/local/bin/; \
    tar -xJf wt.tar.xz; \
    install -m 755 worktrunk-aarch64-unknown-linux-musl/wt worktrunk-aarch64-unknown-linux-musl/git-wt \
      /out/usr/local/bin/; \
    gunzip -c tree-sitter.gz > /build/usr/local/bin/tree-sitter; \
    chmod 755 /build/usr/local/bin/tree-sitter

# Rust for the Rust matcher of blink.cmp, in /build/usr/local. Debian's rustc 1.85 is too old for it.
FROM fetch AS rust
ARG RUST_VERSION=1.99.1
ARG RUSTC_SHA256=acdcdfe09ae1f103aa9a2b7f88903a9588bc2e99288af10e6fbf5514e2e49f25
ARG CARGO_SHA256=5156832e0c1254e9b49a79edabdc6d4c35f32f8fc1cf3ca700f268ff96087ab0
ARG RUST_STD_SHA256=e25668477083d6a9ddb87b9beb9c00742225f38233ccb4bfba3afa7a07427f52
RUN set -e; \
    d=https://static.rust-lang.org/dist; \
    t=aarch64-unknown-linux-gnu; \
    fetch rustc.tar.xz "$d/rustc-$RUST_VERSION-$t.tar.xz" "$RUSTC_SHA256"; \
    fetch cargo.tar.xz "$d/cargo-$RUST_VERSION-$t.tar.xz" "$CARGO_SHA256"; \
    fetch rust-std.tar.xz "$d/rust-std-$RUST_VERSION-$t.tar.xz" "$RUST_STD_SHA256"; \
    for c in rustc cargo rust-std; do \
      tar -xJf "$c.tar.xz"; \
      "./$c-$RUST_VERSION-$t/install.sh" --prefix=/build/usr/local --disable-ldconfig; \
    done

# The LazyVim plugins at their lock commits, the treesitter parsers and the Rust matcher of blink.cmp, built with
# Rust, gcc and the tree-sitter CLI.
FROM claude-kit AS nvim-build
USER root
COPY --from=releases /out/ /build/ /
COPY --from=rust /build/ /
COPY <<'EOF' /tmp/install-parsers.lua
-- Installs the parsers of LazyVim's list. LazyVim starts the same installs in the background when nvim-treesitter
-- loads, and nvim-treesitter waits only 60 s for an install that runs already. So the script also waits, up to
-- 10 min, until nvim-treesitter's parser folder has every parser of the list.
local TS = require("nvim-treesitter")
local want = LazyVim.opts("nvim-treesitter").ensure_installed
TS.install(want):wait(1800000)
vim.wait(600000, function()
  local have = TS.get_installed("parsers")
  for _, lang in ipairs(want) do
    if not vim.list_contains(have, lang) then
      return false
    end
  end
  return true
end, 500)
EOF
COPY <<'EOF' /tmp/verify.lua
-- Fails the build when a plugin, a parser of LazyVim's list or the Rust matcher of blink.cmp is missing.
-- The parsers count only in nvim-treesitter's parser folder: Neovim's bundled ones (c, lua, markdown, vim, vimdoc)
-- do not.
local missing = {}
for _, plugin in ipairs(require("lazy").plugins()) do
  if not plugin._.installed then
    missing[#missing + 1] = plugin.name
  end
end
local parsers = require("nvim-treesitter").get_installed("parsers")
for _, lang in ipairs(LazyVim.opts("nvim-treesitter").ensure_installed) do
  if not vim.list_contains(parsers, lang) then
    missing[#missing + 1] = "parser " .. lang
  end
end
if not require("blink.cmp").library_available() then
  missing[#missing + 1] = "the Rust matcher of blink.cmp"
end
if #missing > 0 then
  io.stderr:write("missing: " .. table.concat(missing, ", ") .. "\n")
  os.exit(1)
end
EOF
USER agent
RUN mkdir -p /home/agent/.config
COPY --chown=agent:agent files/nvim /home/agent/.config/nvim
# lazy.nvim and LazyVim at their lock commits before the first start. Without LazyVim, lazy.nvim installs in two
# rounds, and its lock update after the first round drops the entries of the plugins that only LazyVim's specs name:
# the second round installs those at their branch head.
RUN set -e; \
    lock=/home/agent/.config/nvim/lazy-lock.json; \
    for repo in folke/lazy.nvim LazyVim/LazyVim; do \
      name=${repo#*/}; \
      dir=/home/agent/.local/share/nvim/lazy/$name; \
      git clone -q --filter=blob:none -b "$(jq -r --arg n "$name" '.[$n].branch' "$lock")" \
        "https://github.com/$repo.git" "$dir"; \
      git -C "$dir" checkout -q "$(jq -r --arg n "$name" '.[$n].commit' "$lock")"; \
    done
# One nvim process for the plugins and the parsers: a quit during LazyVim's background parser installs leaves
# tree-sitter lock files, and a second process waits 30 s on each and fails.
RUN nvim --headless "+Lazy! restore" "+luafile /tmp/install-parsers.lua" +qa
# blink.cmp keeps its library in lib/; target/ holds only cargo's build files (110 MB).
RUN rm -rf /home/agent/.local/share/nvim/lazy/blink.cmp/target
# The verify step is the gate for the steps above. run-lua exits 1 when verify.lua raises an error; nvim
# "+luafile <file>" +qa exits 0 after one.
COPY --chmod=755 nvim-build/run-lua /usr/local/bin/run-lua
RUN run-lua /tmp/verify.lua

FROM claude-kit
LABEL sbx-stack.claude-kit=2.1.314

ARG OMZ_COMMIT=17a2b4c3a5855524ad4772a17ada0dc474e2fdf3
ARG FSH_COMMIT=3d574ccf48804b10dca52625df13da5edae7f553
ARG FZF_TAB_COMMIT=24105b15714bfec37989ed5c5b6e60f572253019

ENV SBX_STACK=/usr/local/share/sbx-stack
USER root

RUN set -e; \
    clone() { mkdir -p "$1"; git -C "$1" init -q; git -C "$1" fetch -q --depth 1 "$2" "$3"; git -C "$1" checkout -q FETCH_HEAD; rm -rf "$1/.git"; }; \
    clone "$SBX_STACK/oh-my-zsh" https://github.com/ohmyzsh/ohmyzsh.git "$OMZ_COMMIT"; \
    clone "$SBX_STACK/oh-my-zsh-custom/plugins/fast-syntax-highlighting" \
      https://github.com/zdharma-continuum/fast-syntax-highlighting.git "$FSH_COMMIT"; \
    clone "$SBX_STACK/oh-my-zsh-custom/plugins/fzf-tab" https://github.com/Aloxaf/fzf-tab.git "$FZF_TAB_COMMIT"

# The apt packages and the Claude plugins have no pin. A new REFRESH value (build.sh passes the build time) runs the
# steps from here on again, so each build installs their newest version. The apt lists stay in the build cache and
# never reach the image.
ARG REFRESH
COPY apt-packages.txt /tmp/apt-packages.txt
RUN --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
 && xargs -a /tmp/apt-packages.txt env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
 && rm /tmp/apt-packages.txt \
 && ln -sf /usr/bin/batcat /usr/local/bin/bat \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd

COPY files/zsh $SBX_STACK/zsh
COPY files/git $SBX_STACK/git
COPY files/claude $SBX_STACK/claude
COPY files/starship.toml $SBX_STACK/starship.toml
RUN printf '\nsource %s/zsh/zshrc\n' "$SBX_STACK" >> /etc/zsh/zshrc \
 && usermod -s /usr/bin/zsh agent \
 && install -o agent -g agent -m 644 /dev/null /home/agent/.zshrc \
 && install -o agent -g agent -d /home/agent/.config \
 && install -D -m 644 "$SBX_STACK/claude/managed-settings.json" /etc/claude-code/managed-settings.json \
 && git config --system --add include.path "$SBX_STACK/git/aliases.gitconfig"
COPY --from=releases /out/ /

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
COPY --from=nvim-build --chown=agent:agent /home/agent/.config/nvim /home/agent/.config/nvim
COPY --from=nvim-build --chown=agent:agent /home/agent/.local/share/nvim /home/agent/.local/share/nvim
COPY --chown=agent:agent files/yazi /home/agent/.config/yazi

USER root
ARG GIT_USER_NAME=
ARG GIT_USER_EMAIL=
RUN { [ -z "$GIT_USER_NAME" ] || git config --system user.name "$GIT_USER_NAME"; } \
 && { [ -z "$GIT_USER_EMAIL" ] || git config --system user.email "$GIT_USER_EMAIL"; }

ARG VERSION
ARG REVISION
RUN printf '%s %s\n' "$VERSION" "$REVISION" > "$SBX_STACK/VERSION"
USER agent
