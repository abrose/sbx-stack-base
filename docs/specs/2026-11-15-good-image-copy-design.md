# A copy of the good image outside docker: design

Status: approved by the owner on 2026-11-15. Size: a small change to `build.sh`, its unit tests and the README.

## Intent

`build.sh` keeps the last image that passed the check under the docker tag `sbx-stack-base:good`. The tag lives in
docker only. `docker image prune -a` and `docker system prune -a` remove each image that no container uses, so they
remove this image too.

What the owner loses then (read from `build.sh`, 2026-11-15):

| Loss | Effect |
|---|---|
| The restore after a failed check | The failed template stays loaded in sbx |
| The kit label, the refresh values and the plugin lock of the good image | The next plain `build.sh` is a full update: the newest Claude kit, each layer and each Neovim plugin in its newest version. Nobody asked for it |

The second loss is the larger one: a build that must change nothing changes everything.

## Goals, non-goals, anti-goals

- Goal: after a prune of docker, the next `build.sh` has the good image again, with no step of the owner.
- Goal: the copy is the good image of this moment, or it does not exist.
- Non-goal: a copy of docker's build cache. The copy brings back the kit label, the refresh values and the plugin
  lock. The versions of the layers also need the build cache: after a prune that empties it, each layer builds again
  and takes its newest versions (review, 2026-11-15).
- Non-goal: a copy of `sbx-stack-base:previous`. After a prune, `build.sh --rollback` says that it has no image to
  roll back to, as today. The owner asked for one image.
- Non-goal: a compression step of our own. `docker image save` writes the layers as docker stores them: the file
  has 0.97 GB for the image of 3.8 GB, and a save takes about 8 s (measured on 2026-11-15).
- Anti-goal: a copy that is older than the good image. A build from it would take old refresh values, and the build
  cache would then give older versions of the tools with no message.
- Anti-goal: a broken copy that `build.sh` skips with no message, so that the full update happens anyway.

## Approaches

| Approach | Trade-off |
|---|---|
| **A tar file outside docker and sbx, written with `docker image save` (picked)** | It survives each prune, a reset of Docker Desktop and `sbx reset`. It costs one file of about 1 GB and one more save for each passed build |
| Take the image back from the sbx template store | No more disk use. But sbx v0.53.0 has no command that exports a loaded template: `sbx template save` makes a snapshot of a sandbox, which is another image |
| A stopped container that holds the good image | No file. But `docker container prune` and `docker system prune` remove a stopped container, and then the image |

The owner picked the first approach.

## The design

### The file

| What | Value |
|---|---|
| Path | `${XDG_STATE_HOME:-$HOME/.local/state}/sbx-stack-base/good.tar` |
| Another path | none. A variable for another path would leave a copy at this path, older than the good image (review, 2026-11-15). The unit tests set `XDG_STATE_HOME` |
| Content | the output of `docker image save sbx-stack-base:good`, so a load gives the tag `good` again |

The folder is not in the repo, not in docker and not in the sbx store. It is a state folder, not a cache folder:
cleanup tools empty cache folders.

### When `build.sh` writes the copy

With each move of the tag `good`: after a passed check, and at the end of `build.sh --rollback`.

1. `build.sh` removes the old copy. It does this before the tag moves, so a run that stops in the next steps leaves
   no copy, and never an older one.
2. The tag `good` moves.
3. `build.sh` saves the image to `good.tar.new`. After a save with no error, it renames the file to `good.tar`, so
   the name `good.tar` never holds a part of a file.
4. When the save fails (a full disk), `build.sh` removes `good.tar.new` and says that there is no copy now. The build
   still ends with success: the image passed the check and is loaded.
5. At each end of a run, `build.sh` removes `good.tar.new`. So a run that a signal stops during the save leaves no
   part of a file, and the next run removes the part that a kill or a loss of power left (review, 2026-11-15).

`build.sh` saves after each passed build, also when the image did not change. So no second file must record which
image the copy holds, and a copy that the owner deleted comes back with the next build.

A failed check and a failed build do not touch the copy: `good` did not move.

### When `build.sh` reads the copy

At the start of a build, when docker has no `sbx-stack-base:good` image. A rollback does not read the copy: it needs
the `previous` image, and it moves `good` itself.

| State | What `build.sh` does |
|---|---|
| The copy exists and loads | It says "restored the good image from `<path>`" and goes on. The build keeps the kit, the refresh values and the plugin lock |
| docker does not answer | It stops before the build and says so. It does not name the copy as the cause |
| The copy exists and does not load, or gives no `good` tag | It stops before the build, with the path. The owner removes a broken file to build with no good image |
| The copy path cannot be read: a file with no read permission, a link to nothing, a folder, or a folder above it that cannot be searched | It stops before the build, with the path. It does not take such a path as "no copy" (review, 2026-11-15) |
| No copy: nothing has the name, and the first folder above it that exists can be searched | As today: the warning, then a build that takes the newest version of everything |

`build.sh` does not load the restored image into sbx: the sbx store still has its template.

### The README

The line on `docker image prune -a` says what the copy is, where it is, its size, and that `previous` has no copy.

## Tests

In `tests/build.sh`, with the stubs of docker and sbx. Each assertion comes first and fails for the right reason.

1. A passed build saves `sbx-stack-base:good` to the copy path, and no `.new` file stays.
2. A failed check does not change the copy.
3. A rollback writes the copy again.
4. No `good` in docker, and a copy: the build loads it, prints no "cannot restore" warning, and gets the kit and the
   plugin lock of the good image.
5. No `good` in docker, and a copy that does not load: `build.sh` stops, and docker gets no build command.
6. No `good` in docker, and no copy: the warning of today.
7. A save that fails: the old copy is gone, the message names it, and the build ends with success.
8. A build that stops after the tag `good` moved: the copy holds the new good image, not the old one.
9. A rollback with no `good` and no `previous` image does not load the copy.
10. The path comes from `XDG_STATE_HOME`, or from `HOME`. No other variable changes it.
11. A run that dies during the save leaves no copy, never the old one.
12. docker does not answer: `build.sh` stops, says so, and does not name the copy.
13. A run that gets a signal during the save leaves no `.new` file. A `.new` file from a killed run goes with the next
    run, also when that run does not pass.
14. A copy path that cannot be read (a link to nothing, a folder, a folder that cannot be searched, a file with no
    read permission): `build.sh` stops, says so, and docker gets no build command.

One real run on the Mac after the unit tests: remove the tag `good` (the tag only), run `bash build.sh`, and see the
restore line and a build that comes from the cache.

## Left to the builder

- The names of the functions in `build.sh`.
- The exact words of the messages.
- The measured time of the save, as one line in the README.
