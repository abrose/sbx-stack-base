# A version that shows a change: design

Status: approved by the owner on 2026-11-15. Size: a small change to `build.sh` and its checks, and one
edit of the files that name the template.

## Intent

The owner added a plugin, built the image, and the template was still `sbx-stack-base:0.2.0`. The version must
show that the image changed. No project must stay on an older image.

Today the tag `sbx-stack-base:<VERSION>` is two things: the version, and the name that project files and kit
tests point to. So a new version breaks each pointer. `build.sh` never changes `VERSION`.

## Goals, non-goals, anti-goals

- Goal: a build can raise the version, and `sbx template ls` shows the new version.
- Goal: a bump of the minor or the patch level changes no file outside this repo.
- Goal: a build with no terminal (an agent, `tests/build.sh`) never waits for an answer.
- Non-goal: a project that stays on an older image. The files name a tag that moves.
- Non-goal: pinned tool versions. The repo stays ever-green.
- Anti-goal: `VERSION` names a version that never passed the check.
- Anti-goal: a file that names the old tag gets an old image with no error.

## Approaches

| Approach | Trade-off |
|---|---|
| **Two tags: the major version for the files, the full version for the eye (picked)** | One edit of the files that name `0.2.0` now, then only at a major bump. sbx holds one image under two tags with no more disk use (probe, 2026-11-15) |
| The full version stays in the one tag; a script changes all files at each bump | Each file names the exact image. Each bump means commits in five repos and new kit pins |
| Two tags, with an automatic build id (date and commit) in place of the levels | No question at a build, no bump to forget. The number does not say how large the change is |

The owner picked the first approach.

## The design

### The tags

| Tag | Where | What |
|---|---|---|
| `sbx-stack-base:<major>` (now `sbx-stack-base:0`) | docker and sbx | the tag that project files and kit tests name; it moves with each passed build |
| `sbx-stack-base:<version>` (for example `0.3.0`) | docker and sbx | the same image, so that the version is in `sbx template ls`; one version tag at a time |
| `sbx-stack-base:good`, `sbx-stack-base:previous` | docker | as today |

### The levels

| Level | When | Example |
|---|---|---|
| major | a kit or a project file must change: a path, the user, the layout | `0.2.0` to `1.0.0` |
| minor | a new part: a tool, a plugin, a layer, a setting | `0.2.0` to `0.3.0` |
| patch | the same parts in newer versions (`--update`), or a fix | `0.2.0` to `0.2.1` |
| none | the version stays | |

### The command

```text
build.sh [--bump major|minor|patch|none] [--update [layer...]]
build.sh --rollback
```

- With `--bump`, `build.sh` asks nothing.
- With no `--bump` and a terminal on stdin, `build.sh` asks before the build. Enter means `none`.
- With no `--bump` and no terminal, the level is `none`, and `build.sh` says so in one line.
- `--bump` with another word, and a `VERSION` that is not `x.y.z`, stop the script before the build.

The prompt:

```text
the version is 0.2.0. Which level does this build bump?
  none   0.2.0  (Enter)
  patch  0.2.1  the same parts in newer versions, or a fix
  minor  0.3.0  a new part: a tool, a plugin, a layer, a setting
  major  1.0.0  a kit or a project file must change
level:
```

A wrong answer asks again.

### The build

1. `build.sh` computes the new version and builds the image with it. The image holds the new version in
   `/usr/local/share/sbx-stack/VERSION`, as today.
2. It loads the image as the major tag and runs the check. `build.sh` gives the new version to
   `tests/check.sh` (env `SBX_STACK_VERSION`); with no such value the check reads `VERSION`, as today.
3. When the check passes: it writes `VERSION`, loads the image under the version tag too, and removes the
   version tag of the build before from docker and from sbx. Then `good` and `previous` move, as today.
4. When the build or the check fails: `VERSION` and the version tag stay as they were. The major tag gets the
   good image again, as today. After a failed major bump, the new major tag is removed.

A major bump leaves the old major tag loaded, so a file that still names it keeps the old image until a person
moves it. The README says how to remove an old major tag.

### The rollback

`build.sh --rollback` loads the `previous` image under its major tag and its version tag, writes its version to
`VERSION`, and removes the newer version tag. The version of an image comes from the file
`/usr/local/share/sbx-stack/VERSION` in it, which each image of this repo has. When the major version of the
`previous` image is lower, `build.sh` also removes the newer major tag and says which tag the files must name
again.

### The record of the commit

When the repo has changes that are not committed, the image records the commit with a mark: `<commit>+changes`
(in the file `VERSION` of the image and in the label `org.opencontainers.image.revision`). Today the record
names a commit that does not hold the change. The README gives the order for a clean record: commit the change,
build, then commit `VERSION`.

### The files that name the template

One edit, `sbx-stack-base:0.2.0` to `sbx-stack-base:0`:

| Repo | Files |
|---|---|
| `sbx-stack-base` | `README.md` (the project file example, the `versions.txt` command, the `VERSION` row) |
| `sbx-kit-node` | `README.md`, `tests/sbxenv.yaml`, `tests/sbxenv-empty.yaml` |
| `sbx-kit-github` | `tests/sbxenv.yaml`, `tests/sbxenv-live.yaml` |
| `sbx-kit-playwright` | `tests/sbxenv.yaml`, `tests/sbxenv-node.yaml` |
| `sbx-kit-builder` | `examples/hello/sbxenv.yaml`, the mixin template's `tests/sbxenv.yaml`, `topics/host-side.md`, `tests/facts/f15-state/sbxenv.yaml`, `tests/facts/run.sh`, `tests/sbx-task.sh` |
| the owner's project files | `sandboxOptions.template` |

Plans, old designs and the fact records keep `0.2.0`: they say what was true at their time.

The first build with a bump removes the template `sbx-stack-base:0.2.0` from sbx. A file that still names it
then fails at a create, with `pullPolicy: never`. Until that build, `0.2.0` names the newest image. A sandbox
that exists keeps its own image.

## Tests

`tests/build.sh` (stubs for docker and sbx) gets cases for: each level; `none`; no terminal and no flag; a wrong
level; `VERSION` after a passed check, a failed check and a failed build; the two tags after a passed build;
the removal of the old version tag; the mark for changes that are not committed; the rollback. One real
`build.sh --bump minor` proves the two tags in `sbx template ls` and the check on the major tag.

## Left to the builder

- How the test drives the prompt (a terminal for stdin).
- The wording of the README section.
- The order of the load calls (one file with two tags, or two loads).
