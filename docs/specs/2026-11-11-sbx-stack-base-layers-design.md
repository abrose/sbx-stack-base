# sbx-stack-base: layers and unpinned versions

Status: approved by the owner, 2026-11-11. Changes the build of the base image from
`docs/specs/2026-11-10-sbx-stack-base-image-design.md`. What the image holds stays the same.

## 1. Intent

The base image `sbx-stack-base` is built from one Dockerfile of about 200 lines. The owner does not like it:

- It holds 16 pins in 4 places: versions and sha256 hashes as `ARG` lines, three commit ids, the Claude kit tag with
  its digest, and `files/nvim/lazy-lock.json`.
- No tool updates a pin. An update means: look up the version, download the file, compute the hash, edit by hand.
- Scripts are inline: a `fetch` script, two Lua files, a `clone` function, and one `RUN` that unpacks four tools.
- Concerns are mixed: one stage downloads nvim, yazi and worktrunk; the final stage sets up zsh, git, Claude and yazi.

The owner wants to update often and with no effort, and wants to find everything about one tool in one place.

## 2. Goals, non-goals, anti-goals

Goals:

1. One folder per concern (a "layer"). The folder holds everything about it: scripts, config files, package lists.
2. The Dockerfile only wires the layers together. It holds no version, no hash, no inline script and no logic.
3. No pins. Every build installs the newest version of everything, the Claude kit included.
4. An update is one command: `build.sh`. No file edit.
5. The build records what it installed, in the image and on the terminal.
6. The scripts are simple and readable by a human: short, plain shell, one job each.

Non-goals:

- Separate images per layer, or layers that a project picks from. The result is one image.
- A rebuild of an old state. With no pins, the repo cannot reproduce an earlier image.
- A change of what the image holds or of how projects use it (`sandboxOptions.template`).

Anti-goals:

- A generated Dockerfile, a custom layer framework, or helper code that is harder to read than the code it replaces.
- A failed or bad build that leaves the owner with no working template.

## 3. Decisions the owner made

- Always the newest, with no pins, for simplicity. This was picked over "pins that a command rewrites".
- The Claude kit is unpinned too. Its version in a project file does not have to match the one the image was built on.
  The owner plans frequent updates.
- A folder with scripts per layer and one thin Dockerfile. The scripts stay simple and human-understandable.
- An update checks the new image by itself: `build.sh` runs `tests/check.sh` and goes back to the old image when the
  check fails (5.5).
- The kit mismatch is tested first, before the rest of the work. If it breaks, the owner decides again (5.6).

## 4. Approaches

1. **A folder with scripts per layer, one thin Dockerfile (picked).** All logic is in plain shell scripts that
   shellcheck checks. The Dockerfile fits one screen. Cost: a new layer needs a few lines in the Dockerfile.
2. **One Dockerfile per layer, combined with `docker buildx bake`.** Cleanest separation and parallel builds. Dropped:
   several layers must run commands in the final image (apt, `usermod`, the Claude plugin installs), so there would be
   two kinds of layer and one more tool.
3. **A generated Dockerfile.** A new layer would need no Dockerfile edit. Dropped: a generated file is harder to read
   and to debug than a few lines per layer.

## 5. Design

### 5.1 Layout

```text
sbx-stack-base/
├── Dockerfile              # wires the layers
├── build.sh                # builds, loads, prints the versions
├── layers/
│   ├── lib.sh              # shared helpers, see 5.3
│   ├── tools/              # apt-packages.txt, install.sh
│   ├── zsh/                # zshrc, starship.toml, install.sh (oh-my-zsh and its two plugins)
│   ├── git/                # aliases.gitconfig, install.sh
│   ├── nvim/               # config/, build.sh, install.sh, install-parsers.lua, verify.lua, run-lua
│   ├── yazi/               # config/, install.sh
│   ├── worktrunk/          # install.sh
│   └── claude/             # managed-settings.json, hooks/, statusline, plugins.txt, install.sh
└── tests/
```

The content of `files/` and `nvim-build/` moves into the layer folders. `apt-packages.txt` moves to `layers/tools/`.
The list of Claude marketplaces and plugins moves from the Dockerfile to `layers/claude/plugins.txt`.

### 5.2 The layer contract

- `install.sh` runs in the final image, as root, with the layer folder readable at a fixed path. It installs the
  layer and copies its config files to their place. A step that must run as `agent` does so inside the script.
- `build.sh` is optional. It runs in a build-only stage and writes its result to `/out`. The Dockerfile copies `/out`
  into the final image. Only nvim needs it today: Rust, gcc and the tree-sitter CLI must not reach the image.
- A layer does not read another layer's folder. The order of the layers is the order in the Dockerfile.
- The Dockerfile has one short block per layer, and all blocks look the same.

### 5.3 The newest version, with no pin

| What | How |
|---|---|
| The Claude kit | `FROM docker.io/docker/sbx-kit-claude:latest`, and `docker build --pull` |
| nvim, yazi, worktrunk, the tree-sitter CLI | the GitHub URL `releases/latest/download/<asset>`; the four asset names have no version in them |
| Rust (build stage only) | the newest stable toolchain, minimal profile |
| oh-my-zsh, fast-syntax-highlighting, fzf-tab | a shallow clone of the default branch |
| nvim plugins | no `lazy-lock.json` in the repo; the build installs the newest; `verify.lua` stays the gate |
| apt packages, Claude plugins | as today: no pin |

- The sha256 checks go away with the pins: there is no value to compare with. The build trusts HTTPS and the release
  host, as it does today for apt and the Claude plugins.
- The lock pre-clone workaround in the Dockerfile goes away with the lock.
- A build never reuses a cached download step: each build fetches again. `build.sh` passes the build time as today.
- `lib.sh` holds at most a few small functions, for example "download the newest release asset of a repo" and
  "record a version". If a helper saves less than it costs to read, the layer script does the work inline.

### 5.4 The record of what was installed

- Each layer appends one line per tool to `/usr/local/share/sbx-stack/versions.txt`: the name and the version or
  commit. The Claude kit version, the nvim plugin commits and the Claude plugin versions are in it.
- `build.sh` prints the file after the build. It replaces the plugin list that `build.sh` prints today.

### 5.5 build.sh and the template tag

The owner's decision:

- After the load, `build.sh` runs `tests/check.sh` on the new template. If the check fails, `build.sh` loads the
  image it replaced again and exits with an error. So one command gives a checked image or leaves the old one.
- Only an image that passed the check becomes `sbx-stack-base:previous`. A bad build never replaces the last good
  image, also when two bad builds follow each other.

The designer's calls, for the owner to check:

- `build.sh` always replaces the loaded template. The `--force` flag and the "is loaded already" guard go away:
  a frequent update must be one command.
- The tag stays `sbx-stack-base:<VERSION>`. `VERSION` changes only when the layout of the image changes, not at each
  update. So project files need no edit after an update.
- `build.sh --rollback` loads `sbx-stack-base:previous` again, for a bad image that the check did not catch.
  This is the answer to "no rebuild of an old state".
- A failed build loads nothing: the template in sbx stays as it was.
- After an update, `sbx-task new` warns for each project that has a template saved from the old base. That exists.

### 5.6 The Claude kit in project files

- Project files, the kit template of the kit-builder skill, the example project and the facts probes in
  `sbx-kit-builder` name `docker.io/docker/sbx-kit-claude:latest`. The text "the same version as the FROM of the base
  image" goes away in the skill and the docs.
- In scope are the files of the two repos: the example project, the skill's kit template and topics, the facts
  probes, and `tests/sbxenv.yaml` of `sbx-stack-base`. The owner edits project files that live elsewhere.
- Open fact, and the first step of this work, before any other change: what sbx does when a project file's kit
  differs from the kit the base image was built on. Create a sandbox from the base with an older and a newer kit tag
  where both exist. Record which kit's files and hooks win and whether the create works, as a new fact in
  `docs/facts.md`. The case matters after a rollback: the base is older, and project files still pull the newest kit.
- If the mismatch works, nothing is added. If it breaks a create or the image, stop and ask the owner: the answer
  can change this section, for example to a kit tag that the base records and `sbx-task` uses.

### 5.7 Tests

- `tests/seed.sh`: the Dockerfile holds no version number, no sha256 and no heredoc; each layer folder has an
  executable `install.sh`; no `lazy-lock.json` in the repo. The checks on the config files follow the files to their
  new paths.
- `tests/check.sh`: the lock equality check goes away. A new check: `versions.txt` exists and names every tool of
  section 5.3. The other checks stay; they prove that the new build gives the same image as the old one.
- shellcheck on every script, as today.

## 6. Constraints

- sbx v0.53.0, Docker Desktop with BuildKit, `linux/arm64`, the Mac's bash 3.2 for `build.sh`.
- The scripts in the image run under the image's shell. They follow the owner's bash style: `set -euo pipefail`,
  few comments, no checks for the obvious.
- No secret and no owner name in the repo. The git identity still comes from the Mac's git config at build time.
- The image must still pass the checks of `tests/check.sh` that this design does not remove.

## 7. Left to the builder

- The exact path where a layer folder is readable during its `install.sh`, and whether a bind mount or a `COPY` gives it.
- The functions of `lib.sh`, within 5.3.
- How the nvim build gets the newest stable Rust.
- The format of a line in `versions.txt`.
- The order of the layers, and which steps run as `agent`.
- How `--rollback` keeps and loads the previous image.

## 8. Risks the owner accepts

- An upstream release can break a build or a tool. The old template stays on a failed build or a failed check, and
  `--rollback` restores the last good image after a bad one that the check missed.
- Each update takes about 1 min longer, for the check.
- A compromised release file is not detected by a hash. This is the same trust as for apt and the Claude plugins.
- nvim plugins at their newest commit can break the editor config. `verify.lua` and `tests/check.sh` catch a missing
  plugin, parser or matcher, not a changed behavior.
