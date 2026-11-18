# sbx-stack-base

A personal base image for [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) (`sbx`), built from one folder
per layer.

## What this repo does

Docker Sandboxes runs a coding agent (here: Claude Code) in a microVM on your machine. A new sandbox starts from an
image, and the stock image has the agent and little else. This repo builds an image on top of the stock Claude image
that also holds a full terminal setup, so each new sandbox has it from the first second:

- zsh with oh-my-zsh, a prompt and the usual CLI tools (ripgrep, fd, bat, fzf, eza, zoxide, direnv, ...)
- Neovim with LazyVim, every plugin and treesitter parser already installed
- yazi, lazygit, lazydocker, worktrunk, git aliases
- Claude Code settings, a statusline, safety hooks and plugins

`build.sh` builds the image, loads it into sbx as the template `sbx-stack-base:0` (the major version of the image),
and checks it in a real sandbox. A project then names the template in its `sbxenv.yaml`. The tools and languages of one project (node,
dotnet, ...) do not belong here: they stay sbx kits in the project file.

The repo pins no version. A layer takes the newest version of its tools when it builds, and the image records what
it got. The setup in `layers/` is the owner's taste. To make it yours, fork the repo and edit the layers.

## Requirements

| What | Why |
|---|---|
| A Mac with Apple silicon | the image is `linux/arm64`, and the layers download arm64 release files |
| Docker Desktop with BuildKit | `docker build` with bind, cache and secret mounts |
| `sbx` v0.53.0 (the tested version), signed in | `sbx template load`, `sbx env`; the check creates a real sandbox |
| bash, git, jq, curl | `build.sh` and the tests; the Mac's bash 3.2 is enough |
| Network access at build time | the Claude kit image and its tag list on Docker Hub, apt, GitHub releases and clones, rustup |

Optional: `shellcheck` and `gitleaks`, if you change the scripts.

The build reads the global git `user.name` and `user.email` of the Mac and writes them into the image, so commits
in a sandbox carry your identity. It copies nothing else from the Mac.

## How to use it in a project

1. Build the image and load it as a template. The first build takes about 2 minutes:

   ```bash
   git clone https://github.com/abrose/sbx-stack-base.git
   bash sbx-stack-base/build.sh
   ```

2. Confirm that sbx has the template:

   ```bash
   sbx template ls
   ```

3. Put a file `sbxenv.yaml` into the root of your project. This one is the minimum:

   ```yaml
   schemaVersion: "1"
   agent: sbx-kit-claude
   kits:
     - docker.io/docker/sbx-kit-claude:latest
   workspace: .
   sandboxOptions:
     template: sbx-stack-base:0
     pullPolicy: never
   ```

   - `template` is the image of this repo. The tag is the major version of the image, the first number in the file
     `VERSION`. The tag moves to each new image, so this line stays as it is when the version rises.
   - `pullPolicy: never` tells sbx to use the loaded template and not to look for it in a registry.
   - `workspace: .` mounts the project folder into the sandbox, at the same path as on the Mac.
   - The Claude kit stays in `kits`: it tells sbx how to run the agent. The base image decides which Claude Code
     version runs, not this tag.

4. Create the sandbox. sbx shows a plan and asks before it acts:

   ```bash
   sbx env create --name my-task sbxenv.yaml
   ```

5. Work in it:

   ```bash
   sbx env run --name my-task sbxenv.yaml   # start or join the Claude session
   sbx exec -it my-task zsh                 # a shell in the sandbox
   ```

6. Remove the sandbox when the work is pushed:

   ```bash
   sbx env rm --name my-task sbxenv.yaml
   ```

Without the loaded template, `sbx env create` fails with `image ... is not cached locally and pull_policy=never`.
Run `build.sh` first.

A project file can hold more: ports, environment variables, secrets, more kits. See the sbx documentation for
`sbxenv.yaml`. After `build.sh` built a new image, existing sandboxes keep the image they started from; only a new
sandbox gets the new one.

## Designs

The designs are in `docs/specs/`:

| Design | Content |
|---|---|
| [2026-11-10-sbx-stack-base-image-design.md](docs/specs/2026-11-10-sbx-stack-base-image-design.md) | what the image holds, and why it is an image and not a kit |
| [2026-11-11-sbx-stack-base-layers-design.md](docs/specs/2026-11-11-sbx-stack-base-layers-design.md) | the build from one folder per layer, with no pins |
| [2026-11-12-sbx-stack-base-selective-update-design.md](docs/specs/2026-11-12-sbx-stack-base-selective-update-design.md) | `--update` and the plugin lock |

A later design changes the earlier ones where they differ. The designs name `sbx-kit-builder`: the owner's repo
with the task tool `sbx-task`, the plans and the sbx facts (F1 to F14) with their probes. It is not public; each
fact that a design depends on is stated in the design.

## Build, update, roll back

```bash
bash build.sh                     # updates nothing: only the layers whose files changed build again
bash build.sh --update            # takes the newest version of everything, the Claude kit image included
bash build.sh --update nvim yazi  # takes the newest versions for the named layers only
bash build.sh --rollback          # loads the image that was good before the last one
bash build.sh --load              # loads the good image into sbx again: no build and no check
bash build.sh --bump minor        # as build.sh, and raises the version; goes before --update
```

Nothing in the repo holds the version of a tool, so there is no file to edit for an update. The first build on a
Mac takes the newest version of everything, with or without `--update`.

1. `build.sh` gets the level of the version bump: from `--bump`, or from your answer when it runs in a terminal.
2. It builds the image. A layer builds again when one of its files changed or when `--update` names it.
3. It loads the image into sbx as `sbx-stack-base:<major version>`, the tag that project files name.
4. It runs `tests/check.sh` on the new template.
5. If the check passes, the new image becomes `sbx-stack-base:good`, and the image that was `good` becomes
   `sbx-stack-base:previous`. Then `build.sh` loads the image as `sbx-stack-base:<version>` too, removes each
   other version tag, and writes the new version to `VERSION` as its last step. It prints the version, the image
   size and what the image holds.
6. If the check fails, it loads `sbx-stack-base:good` again and exits 1. If the build fails, it loads nothing. In
   both cases `VERSION` stays as it was.

`build.sh --rollback` is for a bad image that the check did not catch. It loads `sbx-stack-base:previous`, the image
that was good before the last one, under its two tags, and writes its version to `VERSION`. Only a passed check or
a rollback moves `good`, so only an image that passed can become `previous`.

### More than one sbx instance

sbx can run separate instances, one for each Claude account (the repo `sbx-instances`, with its tool
`sbx-instance`). Each instance has its own templates, so each one needs the image.

- **With `sbx-instance` in `PATH`,** the targets of the template are the instances on its list. With no
  `sbx-instance`, `build.sh` works with plain `sbx` only, as before. So this repo does not need the tool.
- **The check runs in the instance of this folder.** `build.sh` calls plain `sbx` for the first load and for the
  check. The `.sbx-instance` file above the repo names that instance. With the tool in `PATH` and no such file,
  `build.sh` stops before the build.
- **After a passed check,** each other instance gets the image with `sbx-instance run <name> -- template load`,
  one after the other. `build.sh` removes each other version tag there too. No other instance gets an image that
  failed the check.
- **If a load into one instance fails,** `build.sh` names the instance, goes on with the next one, and exits 1 at
  its end. The image is good and `VERSION` holds its version all the same. Repair the instance
  (`sbx-instance check`), then run `build.sh --load`.
- **An instance that is not signed in to Docker gets no image,** and counts as a failed load. A typing error in
  the list of `sbx-instance` is such an instance: each sbx call creates the instance of its name, and nobody signed
  it in. So a typing error costs a folder of about 4 KB, not a copy of 4.2 GB.
- **`build.sh --load`** loads the good image into each instance again, under its two tags, and removes each other
  version tag. It builds nothing and runs no check. Use it for a new instance and after a failed load.
- **`build.sh --rollback`** loads the previous image into each instance.
- **If `build.sh` stops during the loads** (a signal, a closed terminal), the image is good and `VERSION` holds
  its version. Run `build.sh --load` then. The same build command again would raise the version a second time.
- **Daemons.** If the daemon of another instance did not run before its load, `build.sh` stops it again after the
  load, unless a sandbox runs in it then: a load takes about a minute, and you can start a sandbox in that time.
  A line then says that the daemon stays running. The daemon of the instance of this folder stays as the check
  left it.
- **Disk.** Each instance holds its own copy of the template: about 4.2 GB for each.

### The version

The image has a version `x.y.z` in the file `VERSION`. One image has two tags in sbx:

| Tag | Use |
|---|---|
| `sbx-stack-base:<major version>`, now `sbx-stack-base:0` | project files and kit tests name this tag; it moves to each new image |
| `sbx-stack-base:<version>`, for example `sbx-stack-base:0.3.0` | shows the version in `sbx template ls`; one such tag exists at a time |

So a new minor or patch version changes no project file. `build.sh` raises the version by one level:

| Level | When | Example |
|---|---|---|
| `major` | a kit or a project file must change: a path, the user, the layout | `0.2.0` to `1.0.0` |
| `minor` | a new part: a tool, a plugin, a layer, a setting | `0.2.0` to `0.3.0` |
| `patch` | the same parts in newer versions (`--update`), or a fix | `0.2.0` to `0.2.1` |
| `none` | the version stays | |

- With `--bump <level>`, `build.sh` asks nothing.
- With no `--bump` in a terminal, `build.sh` asks for the level before the build. Enter means `none`.
- With no `--bump` and no terminal (a script, an agent), the level is `none`.

For a clean record, commit your change, build, and then commit `VERSION`. The image records the commit of the repo
(`/usr/local/share/sbx-stack/VERSION` holds `<version> <commit>`). A build from files that are not committed
records `<commit>+changes`.

After a `major` bump, the old major tag stays loaded with the old image, and a file that still names it gets that
old image. Change the files, then remove the old tag:

```bash
sbx template rm sbx-stack-base:0
docker image rm sbx-stack-base:0
```

What to know about the tags (`<major version>`, `<version>`, `good`, `previous`):

- The new template is loaded while its check runs. If you stop `build.sh` during the check, the unchecked template
  stays loaded. Run `build.sh` again: `good` did not move.
- If `build.sh` stops after the passed check, it says so and `VERSION` stays as it was. Run the same command
  again: it gives the same version, and it removes a version tag that the stopped run left.
- A build that gives the `good` image again (nothing changed) leaves `previous` as it is, so the image to roll back
  to stays. For this, `build.sh` builds with `--provenance=false`: the record of the build that docker adds holds
  the times of the build, so each build would give a new image id. A new commit of the repo gives a new image: the
  image records the commit.
- The tags live in docker. `docker image prune -a` and `docker system prune -a` remove them, and the loaded sbx
  template stays. So `build.sh` keeps a copy of the `good` image outside docker, in the file
  `~/.local/state/sbx-stack-base/good.tar` (below `XDG_STATE_HOME` when it is set). The file has about 1 GB, and
  each passed build and each rollback writes it again (about 8 s).
  - When docker has no `good` image, the next `build.sh` loads the copy and says "restored". The build then keeps
    the Claude kit and the plugin lock of Neovim. It keeps the versions of the layers only while docker's build
    cache has them: after a prune that also empties the build cache (`docker system prune -a`,
    `docker builder prune`), each layer builds again and takes its newest versions.
  - With no `good` image and no copy, `build.sh` warns that it cannot restore an earlier image, and the build takes
    the newest version of everything.
  - A copy that does not load stops the build. If the file is broken, remove it. When docker does not answer,
    `build.sh` says so: the copy is not the cause then.
  - A copy path that `build.sh` cannot read stops the build too: a file with no read permission, a link to
    nothing, a folder, or a folder above the copy that cannot be searched. `build.sh` does not take such a path as
    "no copy".
  - A run that stops during the save leaves no part of a file: `build.sh` removes `good.tar.new` at each end of a
    run.
  - `previous` has no copy: after a prune, `build.sh --rollback` has no image to roll back to.
  - Only this `build.sh` keeps the copy in step with the tag. After a move of `good` by hand (`docker tag`), remove
    the file: a copy that is older than the `good` image gives a later build older versions with no message.
- On the first build there is no `good` image. If its check fails, the failed template stays loaded.

A project template (`sbx-task template <project>` in `sbx-kit-builder`) holds the base it was saved from. After an
update, run `sbx-task template <project>` again for each project with a template. `sbx-task new` warns until then.

| Number (2026-11-12, Apple silicon) | Value |
|---|---|
| Image size | 3700 MB; the Claude kit image alone is 3054 MB |
| `build.sh`, nothing changed | 34 s: every step comes from the cache; the load and the check still run |
| `build.sh` after a new Neovim plugin | 113 s |
| `build.sh --update nvim` | 121 s |
| `build.sh --update` | 124 s |
| Create of `check-base` from the template | 7-9 s |

### What a build keeps and what it updates

A layer that does not build again comes from Docker's build cache, exactly as it was. A layer that builds again
takes the newest version of everything in it.

Each layer has a refresh value: the time of its last `--update`. The image records the values as labels, and
`build.sh` passes the values of `sbx-stack-base:good` again for every layer that `--update` does not name:

```bash
docker image inspect sbx-stack-base:good --format '{{json .Config.Labels}}' | jq 'with_entries(select(.key | startswith("sbx-stack.refresh")))'
```

Three things follow:

- **A layer that builds again also builds the layers after it again.** The order is tools, zsh, git, worktrunk,
  yazi, lazygit, lazydocker, claude, nvim. For example, an edit in `layers/yazi/` or `--update yazi` also updates
  the layers `lazygit`, `lazydocker` and `claude`.
  The `nvim` layer is last and builds in its own stage, so a change there touches no other layer.
- **An edit in `layers/lib.sh` builds every layer again,** because every layer reads it. Neovim, the tree-sitter
  CLI and Rust then take their newest versions too. Only the plugins keep their commits.
- **The same files give the same old layer.** A layer that builds again because of a file edit keeps its refresh
  value. If you later put the files back as they were (a revert, another branch), Docker finds the cache entry
  from before the edit, and the layer and the layers after it go back to the versions of that build, with no
  message. `build.sh --update <layer>` gives the layer a new refresh value and ends that.
- **The cache is Docker's.** After `docker builder prune` or Docker's own cache cleanup, every layer builds again
  with its newest versions.
- **Only `--update` with no layer name takes a newer Claude kit image.** A new kit image builds every layer again.

The `nvim` layer keeps more than the others, because it builds in two steps:

- **Tools** (`build-tools.sh`): Neovim, the tree-sitter CLI and Rust. They change with `--update`, with
  `--update nvim`, and after an edit of `build-tools.sh` or `layers/lib.sh`.
- **Plugins** (`build.sh`): the config, the plugins, the parsers and the matcher. This step runs again when a file
  in `layers/nvim/` changed. Each plugin then keeps its commit, and only a new plugin takes its newest commit:
  `build.sh` reads the plugin lock (`lazy-lock.json`) out of the image `sbx-stack-base:good` and hands it to the
  step. The lock is never in the repo. `--update nvim` hands in an empty lock, so every plugin takes its newest
  commit. lazy.nvim itself is the exception: it follows its release branch `stable`, not the lock.

## Source of truth

This repo holds every file of the image and no version. A layer takes the newest version of each part when it
builds. The
image itself records what it got, in `/usr/local/share/sbx-stack/versions.txt`, one line per part: the layer, the
name, and the version or commit. `build.sh` prints the file after each update.

```bash
docker run --rm --entrypoint cat sbx-stack-base:0 /usr/local/share/sbx-stack/versions.txt
```

What follows from "no versions":

- The repo cannot build an earlier state again. The way back is `build.sh --rollback`, one step deep.
- No sha256 check guards a download. The build trusts HTTPS and the release hosts.
- A new release of a tool can break the build or the check. The loaded template then stays as it was.

Nothing is copied from the Mac at build time, except the git `user.name` and `user.email`.

## What the image holds

| Part | Content | Where |
|---|---|---|
| Base | the Claude kit image `docker/sbx-kit-claude` at its newest version tag: Debian trixie, Claude Code, the user `agent` | |
| CLI tools from apt | zsh, eza, zoxide, starship, btop, fzf, ripgrep, fd-find, bat, shfmt, gitleaks, direnv, file, xz-utils; `bat` and `fd` under their usual names | `/usr/bin`, links in `/usr/local/bin` |
| CLI tools from release files | Neovim, yazi (`yazi`, `ya`), worktrunk (`wt`, `git-wt`), lazygit, lazydocker | `/usr/local/bin`; Neovim in `/opt/nvim` |
| zsh | the login shell of `agent`; oh-my-zsh with fast-syntax-highlighting and fzf-tab; the zshrc, sourced from `/etc/zsh/zshrc` | `/usr/local/share/sbx-stack/` |
| Neovim | the LazyVim config; every plugin at its newest commit; the treesitter parsers of LazyVim's list; blink.cmp's Rust matcher | `~/.config/nvim`, `~/.local/share/nvim` |
| yazi | the yazi config | `~/.config/yazi` |
| git | the aliases; `user.name` and `user.email` from the Mac's global git config at build time | `/etc/gitconfig` |
| Claude | the managed settings (with the default model Opus 5.5 at high effort, and transcripts that stay for 3650 days), the statusline, the safety hooks, and the plugins of `layers/claude/plugins.txt` | `/etc/claude-code/`, `/usr/local/share/sbx-stack/claude/`, `~/.claude/plugins` |
| Version | `<VERSION> <repo commit>`, and `versions.txt` | `/usr/local/share/sbx-stack/` |

Not in the image: the build tools (Rust, the tree-sitter CLI), cargo's build files and the apt lists.

`latest` of the Claude kit is not always its newest version tag (fact F14 in `sbx-kit-builder`). So `build.sh
--update` and the first build ask Docker Hub for the newest version tag (`x.y.z`) and build on it. Every other
build keeps the kit of `sbx-stack-base:good`, which records it as the label `sbx-stack.claude-kit`. The base image
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
| `lazygit` | `lazygit` | |
| `lazydocker` | `lazydocker` | |
| `claude` | the managed settings, the statusline, the hooks, the plugins | `managed-settings.json`, `statusline*`, `hooks/`, `plugins.txt` |
| `nvim` | Neovim, the LazyVim config, the plugins, the parsers, the matcher | `config/`, `install-parsers.lua`, `verify.lua`, `run-lua` |

The contract of a layer:

- `install.sh` runs as root in the final image and installs the layer. The folder `layers/` is readable at `/layers`
  while it runs, and is not in the image afterwards.
- Build scripts are optional. They run in a build-only stage and write their result to `/out`. The layer's
  `install.sh` finds that `/out` and copies it into the image. Only `nvim` has them (`build-tools.sh`, then
  `build.sh`): Rust and the tree-sitter CLI must not ship.
- A layer reads only its own folder and `layers/lib.sh`: its `RUN` line mounts nothing else. The order of the
  layers is their order in the Dockerfile.
- Each layer has a build argument `REFRESH_<LAYER>` just before its `RUN` line. `build.sh --update` gives it a new
  value, and the layer builds again.

`layers/lib.sh` has four helpers: `fetch_latest` (an asset of the newest GitHub release), `clone_head` (the newest
commit of a repo), `record` (a line in `versions.txt`) and `as_agent` (a command as the user `agent`).

The `nvim` build installs the plugins with lazy.nvim and then runs `verify.lua` through `run-lua`. The build fails
when a plugin, a parser or the matcher is missing. Keep Neovim at 0.12 or newer: blink.cmp's main branch needs it.

### The status line of a sandbox

`layers/claude/statusline.sh` is one script for the Mac and for a sandbox. In a sandbox (`IS_SANDBOX` is set and
not empty) it draws the sandbox form. You see at one look that a session runs in a sandbox, and in which instance:

- **The pill.** The first chip is `📦 <instance> · <sandbox>` on a colored background, in the place of the profile
  chip `👤`. `<instance>` is the variable `SBX_INSTANCE`. sbx gives a VM no trace of its instance: the name comes
  from the label that `sbx-instance add` of the repo `sbx-instances` sets for an instance. The pill shows `?` in
  gray when the instance has no label, or when the sandbox is older than the label. A sandbox gets the label at
  its create only.
- **The stripe.** Each of the three rows starts with a bar `▌` in the color of the pill. The rest of each row is
  the row of the Mac. Nothing fills a row, so the width of the terminal does not matter.
- **The color of an instance.** Each instance gets a color from a palette of six: the sum of the bytes of its name
  in UTF-8, modulo six. Two instances can get the same color. The constants `PALETTE`, `GRAY` and `PILL_TEXT` are
  at the top of the script; `tests/statusline.sh` holds the same values.

Outside a sandbox the output does not change. The files `tests/statusline*.expected` hold it for a fixed input,
byte for byte: the default profile, a named profile, a git branch, and quota bars. The files were written with the
script from before the sandbox form, so the tests prove that the form changed nothing on the Mac. After a wanted
change of that output, write the files new: `STATUSLINE_PIN=1 bash tests/statusline.sh`.

### Add a layer

1. Make `layers/<name>/install.sh`, executable, with `set -euo pipefail`. Put the layer's config files beside it.
2. Add the layer to the Dockerfile, at the place in the order where it belongs. `build.sh --update <name>` finds
   the layer by its folder and passes `REFRESH_<NAME>` (upper case, `-` becomes `_`):

   ```dockerfile
   ARG REFRESH_<NAME>
   RUN --mount=type=bind,source=layers/lib.sh,target=/layers/lib.sh \
       --mount=type=bind,source=layers/<name>,target=/layers/<name> \
       /layers/<name>/install.sh
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
bash tests/statusline.sh  # unit tests of the statusline; needs jq, git and python3
bash tests/check.sh     # creates the sandbox check-base from the loaded template, asserts, removes it
```

`build.sh` runs `tests/check.sh` by itself. The check asserts everything twice: after the create, and again after a
stop and start.

## Files

| Path | What |
|---|---|
| `Dockerfile` | wires the layers together: one `RUN` per layer, no version, no logic |
| `build.sh` | docker build, docker image save, sbx template load, the check, the rollback |
| `VERSION` | the image version; `build.sh` raises it after a passed check, see "The version" |
| `LICENSE` | the MIT license |
| `layers/lib.sh` | the helpers of the layer scripts |
| `layers/<name>/` | one layer: `install.sh`, optional build scripts, and its files |
| `tests/seed.sh` | static checks of the files |
| `tests/build.sh` | unit tests of `build.sh` |
| `tests/statusline.sh`, `tests/statusline*.expected` | unit tests of `layers/claude/statusline.sh`, and its outputs outside a sandbox |
| `tests/check.sh`, `tests/sbxenv.yaml` | the check in a sandbox from the template, and its project file |
