# sbx-stack-base: update only what you name

Status: approved by the owner, 2026-11-12; the plugin lock stays out of git. It extends `2026-11-11-sbx-stack-base-layers-design.md`.

## 1. Intent

Since the layers design, `build.sh` runs every layer again and takes the newest version of everything. The owner
wants to change one thing (add a Neovim plugin, edit a config file) and keep the rest of the image as it is.

## 2. Goals, non-goals, anti-goals

Goals:

- `build.sh` with no argument updates nothing. It builds again only the layers whose files changed.
- `build.sh --update` takes the newest version of everything (the behavior of today).
- `build.sh --update <layer>...` takes the newest versions for the named layers only.
- A new Neovim plugin does not move the other plugins to newer commits.

Non-goals:

- Version pins in the repo. "Keep as it is" means "from Docker's build cache", plus the plugin lock of section 5.
- Full independence of the layers (one build stage per layer).

Anti-goals:

- A build that updates a part the owner did not name, without a word about it in the README.
- A change that weakens the check or the rollback.

## 3. Approaches

1. **Default with no update, `--update [layer...]` to update.** Picked by the owner: the cheap and safe action is
   the default.
2. Default updates everything, `--only <layer>` limits it. Same work; the risky action is the default.
3. One build stage per layer, so no layer depends on another. Clean, but apt packages do not fit a `/out` copy, and
   the change is much larger.

## 4. How the build keeps a layer

- Each `RUN` line mounts only its own layer folder and `layers/lib.sh`. Today each line mounts all of `layers/`, so
  an edit in one layer invalidates every layer.
- One build argument per layer, `REFRESH_<LAYER>`, declared just before the layer's `RUN` line. `build.sh` passes
  the build time for each layer that updates and nothing for the others. The single `REFRESH` goes.
- `docker build --pull` runs only for `--update` with no layer name. A new Claude kit image rebuilds everything, so
  no other mode pulls it.
- The check, the tags `good` and `previous`, and `--rollback` do not change.

`build.sh` arguments:

| Call | Effect |
|---|---|
| `build.sh` | no layer updates; changed layers build again |
| `build.sh --update` | every layer updates; the Claude kit image is pulled |
| `build.sh --update nvim yazi` | the named layers update |
| `build.sh --rollback` | as today |
| an unknown layer name, or `--rollback` with other arguments | usage, exit 2 |

The usage line: `usage: build.sh [--update [layer...] | --rollback]`. The layer names are the folders in `layers/`.

## 5. The nvim layer

The nvim build stage splits into two steps, so a config edit does not fetch a new Neovim:

1. **Tools:** Neovim, the tree-sitter CLI, Rust. This step runs again only for `--update` or `--update nvim`.
2. **Plugins:** the config, the plugins, the parsers, the matcher, the verify gate. This step runs again when a
   file in `layers/nvim/` changes, or for an update.

The plugin lock:

- lazy.nvim writes `lazy-lock.json` into the config folder of the image at each build.
- Before a build that does not update nvim, `build.sh` copies `lazy-lock.json` out of the image
  `sbx-stack-base:good` into a git-ignored folder of the build context. The plugins step puts it into the config
  before `Lazy! install`, so each plugin in the lock gets its locked commit. A plugin that is not in the lock gets
  its newest commit.
- For `--update` and `--update nvim`, and when there is no `good` image, `build.sh` writes an empty lock (`{}`).
- The lock is never in git and nobody edits it by hand.
- The parsers follow the commit of nvim-treesitter, so the lock holds them too.

## 6. Limits (the README states each one)

- "Keep" depends on Docker's build cache. After `docker builder prune`, every layer takes its newest version. The
  plugin lock survives that, as long as the `good` image exists.
- A layer that builds again also builds the layers after it in the Dockerfile again, and those take their newest
  versions. The order is tools, zsh, git, worktrunk, yazi, claude, nvim. nvim is last, and its plugins step is in
  its own stage.
- After a build that added a plugin, the lock of the new `good` image differs from the lock that went in. The next
  `build.sh` therefore runs the plugins step one more time, with the same result.
- Inside every layer except nvim, a rebuild updates all of the layer.

## 6b. Changes found during the build (2026-11-12)

- The lock reaches the plugins step as a BuildKit secret mount from a temp file, not from a git-ignored folder. A
  secret is not part of the cache key, so the third limit of section 6 does not exist.
- `build.sh` passes no "nothing" for a kept layer. It passes the layer's last refresh value, which the image
  `good` records as the label `sbx-stack.refresh.<layer>`. With no value, a kept layer matched the cache entry from
  before its last update, and a plain build undid the update.
- lazy.nvim itself does not follow the lock. The config clones its release branch `stable` before the lock is read.

## 7. Tests

- `tests/build.sh`: the build arguments and `--pull` for each call of the table, the usage cases, the lock file
  (copied from `good`, or `{}`).
- `tests/seed.sh`: each `RUN` line mounts only its layer and `lib.sh`; each layer has its `REFRESH_<LAYER>`.
- Real runs: an nvim config edit keeps the other layers and the Neovim version (compare `versions.txt`); a new
  plugin keeps the commits of the other plugins; `--update nvim` moves them; `--update` passes the check.

## 8. Left to the builder

- The names of the two nvim scripts and of the git-ignored lock folder.
- How `build.sh` reads the lock out of the `good` image (`docker run ... cat` or `docker cp`).
- A probe first: `Lazy! install` with a lock in place gives the locked commits. If it does not, use
  `Lazy! restore` after the install.
