# sbx-stack-base

The base image of sbx-stack: the owner's personal setup for Docker Sandboxes (sbx), built from one folder per layer
and loaded into sbx as the template `sbx-stack-base:<VERSION>`. Every project file names it as its template. Project
layers (node, gitlab, ...) stay kits in the project file.

The designs are `docs/specs/2026-11-10-sbx-stack-base-image-design.md` (what the image holds) and
`docs/specs/2026-11-11-sbx-stack-base-layers-design.md` (how it builds) in `sbx-kit-builder`.

## Build, update, roll back

```bash
bash build.sh              # builds with the newest version of everything, loads the template, runs the check
bash build.sh --rollback   # loads the last good image again
```

An update is the same command as the first build. Nothing in the repo holds a version, so there is no file to edit.

1. `build.sh` builds the image. It pulls the newest Claude kit image and runs every layer again.
2. It loads the image into sbx as `sbx-stack-base:<VERSION>`.
3. It runs `tests/check.sh` on the new template.
4. If the check passes, it prints the image size and what the image holds. The image it replaced is kept as
   `sbx-stack-base:previous`.
5. If the check fails, it loads the replaced image again and exits 1. If the build fails, it loads nothing.

`build.sh --rollback` is for a bad image that the check did not catch. It loads `sbx-stack-base:previous`, the last
image that passed the check and was replaced. Only an image that passed can become `previous`.

A project template (`sbx-task template <project>` in `sbx-kit-builder`) holds the base it was saved from. After an
update, run `sbx-task template <project>` again for each project with a template. `sbx-task new` warns until then.

| Number (2026-11-11, Apple silicon) | Value |
|---|---|
| Image size | 3700 MB; the Claude kit image alone is 3054 MB |
| `build.sh`, all of it | 131 s: about 115 s for the build and the load, the rest for the check |
| Create of `check-base` from the template | 7-9 s |

Every build is a full build: no step comes from the build cache.

## Source of truth

This repo holds every file of the image and no version. Each build takes the newest version of each part. The
image itself records what it got, in `/usr/local/share/sbx-stack/versions.txt`, one line per part: the layer, the
name, and the version or commit. `build.sh` prints the file after each update.

```bash
docker run --rm --entrypoint cat sbx-stack-base:0.2.0 /usr/local/share/sbx-stack/versions.txt
```

What follows from "no versions":

- The repo cannot build an earlier state again. The way back is `build.sh --rollback`, one step deep.
- No sha256 check guards a download. The build trusts HTTPS and the release hosts.
- A new release of a tool can break the build or the check. The loaded template then stays as it was.

Nothing is copied from the Mac at build time, except the git `user.name` and `user.email`.

## What the image holds

| Part | Content | Where |
|---|---|---|
| Base | the Claude kit image `docker/sbx-kit-claude:latest`: Debian trixie, Claude Code, the user `agent` | |
| CLI tools from apt | zsh, eza, zoxide, starship, btop, fzf, ripgrep, fd-find, bat, shfmt, gitleaks, direnv, file, xz-utils; `bat` and `fd` under their usual names | `/usr/bin`, links in `/usr/local/bin` |
| CLI tools from release files | Neovim, yazi (`yazi`, `ya`), worktrunk (`wt`, `git-wt`) | `/usr/local/bin`; Neovim in `/opt/nvim` |
| zsh | the login shell of `agent`; oh-my-zsh with fast-syntax-highlighting and fzf-tab; the zshrc, sourced from `/etc/zsh/zshrc` | `/usr/local/share/sbx-stack/` |
| Neovim | the LazyVim config; every plugin at its newest commit; the treesitter parsers of LazyVim's list; blink.cmp's Rust matcher | `~/.config/nvim`, `~/.local/share/nvim` |
| yazi | the yazi config | `~/.config/yazi` |
| git | the aliases; `user.name` and `user.email` from the Mac's global git config at build time | `/etc/gitconfig` |
| Claude | the managed settings, the statusline, the safety hooks, and the plugins of `layers/claude/plugins.txt` | `/etc/claude-code/`, `/usr/local/share/sbx-stack/claude/`, `~/.claude/plugins` |
| Version | `<VERSION> <repo commit>`, and `versions.txt` | `/usr/local/share/sbx-stack/` |

Not in the image: the build tools (Rust, the tree-sitter CLI), cargo's build files and the apt lists.

`latest` of the Claude kit is not always its newest version tag (fact F14 in `sbx-kit-builder`). The base image
decides which Claude Code a sandbox runs, not the kit tag in a project file.

## The layers

A layer is a folder in `layers/`. It holds everything about one concern: its scripts, its config files, its lists.

| Layer | What it installs | Files beside the scripts |
|---|---|---|
| `tools` | the apt packages | `apt-packages.txt`, one package per line |
| `zsh` | oh-my-zsh, two plugins, the zshrc, the prompt, zsh as the login shell | `zshrc`, `starship.toml` |
| `git` | the aliases and the git identity | `aliases.gitconfig` |
| `worktrunk` | `wt` and `git-wt` | |
| `yazi` | `yazi`, `ya` and the config | `config/` |
| `claude` | the managed settings, the statusline, the hooks, the plugins | `managed-settings.json`, `statusline*`, `hooks/`, `plugins.txt` |
| `nvim` | Neovim, the LazyVim config, the plugins, the parsers, the matcher | `config/`, `install-parsers.lua`, `verify.lua`, `run-lua` |

The contract of a layer:

- `install.sh` runs as root in the final image and installs the layer. The folder `layers/` is readable at `/layers`
  while it runs, and is not in the image afterwards.
- `build.sh` is optional. It runs in a build-only stage and writes its result to `/out`. The layer's `install.sh`
  finds that `/out` and copies it into the image. Only `nvim` has one: Rust and the tree-sitter CLI must not ship.
- A layer reads only its own folder and `layers/lib.sh`. The order of the layers is their order in the Dockerfile.

`layers/lib.sh` has four helpers: `fetch_latest` (an asset of the newest GitHub release), `clone_head` (the newest
commit of a repo), `record` (a line in `versions.txt`) and `as_agent` (a command as the user `agent`).

The `nvim` build installs the plugins with lazy.nvim and then runs `verify.lua` through `run-lua`. The build fails
when a plugin, a parser or the matcher is missing. Keep Neovim at 0.12 or newer: blink.cmp's main branch needs it.

### Add a layer

1. Make `layers/<name>/install.sh`, executable, with `set -euo pipefail`. Put the layer's config files beside it.
2. Add one line to the Dockerfile, at the place in the order where the layer belongs:

   ```dockerfile
   RUN --mount=type=bind,source=layers,target=/layers /layers/<name>/install.sh
   ```

3. Record what the layer installs with `record <name> <tool> <version>`.
4. Add the layer's assertions to `tests/check.sh` and its `install.sh` to the list in `tests/seed.sh`.
5. Run `bash tests/seed.sh` and `bash build.sh`.

### Change what a layer installs

- An apt package: a line in `layers/tools/apt-packages.txt`.
- A Claude plugin or marketplace: a line in `layers/claude/plugins.txt`, and the plugin's key in `enabledPlugins`
  of `layers/claude/managed-settings.json`.
- A Neovim plugin: a file in `layers/nvim/config/lua/plugins/`.

## Tests

```bash
bash tests/seed.sh      # static checks of the repo files, no Docker
bash tests/build.sh     # unit tests of build.sh; docker and sbx are stubs
bash tests/check.sh     # creates the sandbox check-base from the loaded template, asserts, removes it
```

`build.sh` runs `tests/check.sh` by itself. The check asserts everything twice: after the create, and again after a
stop and start.

## Files

| Path | What |
|---|---|
| `Dockerfile` | wires the layers together: one `RUN` per layer, no version, no logic |
| `build.sh` | docker build, docker image save, sbx template load, the check, the rollback |
| `VERSION` | the image version; it changes only when the layout of the image changes |
| `layers/lib.sh` | the helpers of the layer scripts |
| `layers/<name>/` | one layer: `install.sh`, an optional `build.sh`, and its files |
| `tests/seed.sh` | static checks of the files |
| `tests/build.sh` | unit tests of `build.sh` |
| `tests/check.sh`, `tests/sbxenv.yaml` | the check in a sandbox from the template, and its project file |
