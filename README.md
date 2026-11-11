# sbx-stack-base

The base image of sbx-stack: the owner's personal setup for Docker Sandboxes (sbx), built from a Dockerfile and
loaded into sbx as the template `sbx-stack-base:<VERSION>`. Every project file names it as its template. Project
layers (node, gitlab, ...) stay kits in the project file.

The design is `docs/specs/2026-11-10-sbx-stack-base-image-design.md` in `sbx-kit-builder`.

## Build and check

```bash
bash tests/seed.sh      # static checks of files/, no Docker
bash build.sh           # builds sbx-stack-base:<VERSION> and loads it into sbx; --force replaces a loaded one
bash tests/check.sh     # creates the sandbox check-base from the template, asserts, removes it
```

`build.sh` prints the image size and the version and commit of each Claude plugin. `tests/check.sh` asserts
everything twice: after the create, and again after a stop and start.

| Number (2026-11-11, Apple silicon) | Value |
|---|---|
| Image size | 3697 MB; the Claude kit image alone is 3054 MB |
| Create of `check-base` from the template | 8 s |
| Rebuild with no change | 31 s: the apt packages and the Claude plugins install again, all else comes from the build cache |
| Rebuild after a change in `files/nvim/` | about 90 s more: the plugins, the parsers and the blink.cmp matcher build again |
| First build, empty build cache | about 20 min on 2026-11-10, when GitHub and deb.debian.org sent 0.1-2 MB/s; the downloads take most of it |

## Source of truth

This repo holds every file of the image and pins its versions, with two exceptions: the apt packages and the
Claude plugins take their newest version at each build. `build.sh` prints the version and commit of each plugin
after the build, so a rebuild shows what changed. The configs in `files/` started as a one-time seed from the
owner's dotfiles (zsh, LazyVim, yazi) and are kept here by hand from now on. Nothing is copied from the Mac at
build time, except the git `user.name` and `user.email`.

## What the image holds

| Part | Content | Where |
|---|---|---|
| Base | the Claude kit image `docker/sbx-kit-claude`, by tag and digest: Debian trixie, Claude Code, the user `agent` | |
| CLI tools from apt | zsh, eza, zoxide, starship, btop, fzf, ripgrep, fd-find, bat, shfmt, gitleaks, direnv, file; `bat` and `fd` under their usual names | `/usr/bin`, links in `/usr/local/bin` |
| CLI tools from release files | Neovim, yazi (`yazi`, `ya`), worktrunk (`wt`, `git-wt`) | `/usr/local/bin`; Neovim in `/opt/nvim` |
| zsh | the login shell of `agent`; oh-my-zsh with fast-syntax-highlighting and fzf-tab; `files/zsh/zshrc`, sourced from `/etc/zsh/zshrc` | `/usr/local/share/sbx-stack/` |
| Neovim | the LazyVim config; every plugin at its lock commit; the treesitter parsers of LazyVim's list; blink.cmp's Rust matcher | `~/.config/nvim`, `~/.local/share/nvim` |
| yazi | the yazi config | `~/.config/yazi` |
| git | the aliases; `user.name` and `user.email` from the Mac's global git config at build time | `/etc/gitconfig` |
| Claude | the managed settings, the statusline, the safety hooks, and the plugins adhd-friendly-simple-technical-english, quota-statusline, hookify and superpowers | `/etc/claude-code/`, `/usr/local/share/sbx-stack/claude/`, `~/.claude/plugins` |
| Version | `<VERSION> <repo commit>` | `/usr/local/share/sbx-stack/VERSION` |

Not in the image: the build tools (Rust, the tree-sitter CLI), cargo's build files and the apt lists.

## How the build works

The Dockerfile has build-only stages. Only the last stage ships.

| Stage | What it does |
|---|---|
| `fetch` | installs xz-utils and a `fetch` script that fails when the sha256 of a download differs |
| `releases` | downloads Neovim, yazi, worktrunk and the tree-sitter CLI |
| `rust` | installs Rust from the three official files rustc, cargo and rust-std |
| `nvim-build` | clones lazy.nvim and LazyVim at their lock commits, then starts nvim once: lazy.nvim installs the other plugins at their lock commits, nvim-treesitter builds the parsers, and cargo builds blink.cmp's matcher. A verify step fails the build when a plugin, a parser or the matcher is missing |
| final | the Claude kit image with the apt packages, zsh, the configs and the Claude plugins, plus the release files and the Neovim files from the stages above |

`build.sh` passes the build time as the build arg `REFRESH`. So each build runs the apt install and the Claude
plugin installs again, and takes their newest versions. The other steps come from the build cache until their input
changes. The apt lists stay in a build cache that all builds share, so they never reach the image.

## Update a dependency

| Dependency | Pin | How to update |
|---|---|---|
| Claude Code and the OS | `FROM docker.io/docker/sbx-kit-claude:<version>@sha256:<digest>` | change the tag, the digest and the `sbx-stack.claude-kit` label, bump `VERSION`, rebuild; then change the Claude kit version in `tests/sbxenv.yaml` and in the project files |
| apt packages | the names in `apt-packages.txt`; the versions float | rebuild |
| Neovim, yazi, worktrunk, the tree-sitter CLI | version and sha256 of the linux/arm64 release file, as Dockerfile ARGs | change both ARGs, rebuild |
| Rust | `RUST_VERSION` and the sha256 of the rustc, cargo and rust-std files | change the four ARGs, rebuild |
| oh-my-zsh, fast-syntax-highlighting, fzf-tab | `OMZ_COMMIT`, `FSH_COMMIT`, `FZF_TAB_COMMIT` | change the commit, rebuild |
| LazyVim and the Neovim plugins | `files/nvim/lazy-lock.json` | see "Update the Neovim plugins" |
| Claude plugins | none: each build installs the newest version | rebuild; `build.sh` prints what it installed |

The sha256 of a GitHub release file:

```bash
curl -fsSL https://github.com/neovim/neovim/releases/download/v0.12.6/nvim-linux-arm64.tar.gz | shasum -a 256
```

Rust publishes the sha256 of each file next to the file:

```bash
curl -fsS https://static.rust-lang.org/dist/rustc-1.99.1-aarch64-unknown-linux-gnu.tar.xz.sha256
```

Keep Neovim at 0.12 or newer: blink.cmp's main branch needs it. LazyVim needs 0.11.2, and `tests/check.sh` checks
only that floor. A newer blink.cmp commit can need a newer Rust: the verify step then fails the build and names the
matcher.

### Update the Neovim plugins

GitHub is closed in a sandbox, so the update runs in a container of the build stage. Run this in the repo root:

```bash
docker build --target nvim-build -t sbx-stack-base-nvim .
docker run --rm --entrypoint sh -v "$PWD/files/nvim:/repo" sbx-stack-base-nvim \
  -c 'nvim --headless "+Lazy! update" +qa && nvim --headless +qa && cp ~/.config/nvim/lazy-lock.json /repo/'
docker image rm sbx-stack-base-nvim
bash build.sh --force && bash tests/check.sh
```

1. `Lazy! update` moves each plugin to the head of its branch and writes the new lock.
2. The second nvim start installs the plugins that a new LazyVim version adds, and adds them to the lock.
3. The rebuild installs every plugin at its new lock commit. `tests/check.sh` fails when the image's lock differs
   from the repo's, and names each plugin that differs.
4. When the check passes, commit the lock.

## Files

| Path | What |
|---|---|
| `Dockerfile` | the build; every pinned version is an ARG or a commit |
| `build.sh` | docker build, docker image save, sbx template load |
| `VERSION` | the image version |
| `apt-packages.txt` | the Debian packages, one per line |
| `files/zsh/zshrc` | the zsh config, sourced from `/etc/zsh/zshrc` |
| `files/starship.toml`, `files/git/` | the prompt and the git aliases |
| `files/nvim/` | the LazyVim config with `lazy-lock.json`, to `~/.config/nvim` |
| `files/yazi/` | the yazi config, to `~/.config/yazi` |
| `files/claude/` | `managed-settings.json` (to `/etc/claude-code/`), the statusline and the safety hooks |
| `tests/seed.sh` | static checks of the files |
| `tests/check.sh`, `tests/sbxenv.yaml` | the check in a sandbox from the template, and its project file |
