# sbx-kit-base

A schema 3 mixin layer of sbx-stack: zsh with oh-my-zsh and starship, CLI tools, git aliases and identity, and the
owner's Claude setup (statusline, output style, hooks, plugins from git marketplaces). Built for the Debian-based
Claude kit `docker.io/docker/sbx-kit-claude:2.1.314`.

## Use it

```yaml
# sbx-projects/<project>/sbxenv.yaml
kits:
  - docker.io/docker/sbx-kit-claude:2.1.314
  - source: git+https://github.com/<owner>/sbx-kit-base.git#ref=<40-hex sha>
    args:
      gitUserName: Your Name
      gitUserEmail: you@example.com
sandboxOptions:
  skills: "off"
```

Set `sandboxOptions.skills: "off"`: otherwise sbx mounts the Mac's skill store read-only on `~/.claude/skills`.

## Args

| Arg | Default | Meaning |
|---|---|---|
| `gitUserName` | empty | git `user.name` in the VM's system config; empty leaves it unset |
| `gitUserEmail` | empty | git `user.email` in the VM's system config; empty leaves it unset |
| `plugins` | empty | space-separated `name@marketplace`, installed after the ever-green plugins |
| `marketplaces` | `claude-plugins-official=anthropics/claude-plugins-official abrose-plugins=abrose/claude-plugins` | space-separated `name=owner/repo` on GitHub, added before the installs |

The ever-green plugins: `adhd-friendly-simple-technical-english@abrose-plugins`, `quota-statusline@abrose-plugins`,
`hookify@claude-plugins-official`, `superpowers@claude-plugins-official`. `context7` is not one of them: its
marketplace MCP URL asks for OAuth and would put a token in the VM.

## What it does

| When | What |
|---|---|
| Build (the recipe) | `files/` goes read-only to `/usr/local/share/sbx-stack` |
| Install (root) | apt: `zsh eza zoxide starship btop fzf ripgrep fd-find bat shfmt gitleaks`; oh-my-zsh, `fast-syntax-highlighting` and `fzf-tab` at pinned commits; zsh as the login shell; the git aliases and identity in `/etc/gitconfig` |
| Install (agent) | marketplace adds and plugin installs; one line per step with its exit code in `~/.sbx-stack/plugins.log`, the output in `~/.sbx-stack/plugins.out`; a failure never blocks the sandbox |
| Every boot (agent) | merges `files/claude/settings.json` into `~/.claude/settings.json`; a second run changes nothing |

Every install step checks first, then installs: a sandbox made from a template runs the install steps again.

## Network rules

| Phase | Hosts | Methods and paths |
|---|---|---|
| install | `github.com`, `codeload.github.com`, `raw.githubusercontent.com`, `objects.githubusercontent.com`, `api.github.com` | all |
| install | `deb.debian.org`, `dhi.io` | GET, HEAD |
| runtime | none | |

This kit owns the apt archive rule. sbx refuses the same rule in two kits, so other kits must not declare it.

## Update the files from the Mac

```bash
bash host/sync-from-mac.sh ~/.claude-profiles/<profile>
git diff
```

The script copies `~/.config/starship.toml`, the profile's `statusline.sh`, six hooks and two libs from
`~/.claude/hooks`, and the profile's `outputStyle`, `tui` and hook entries with VM paths. It fails if a Mac home
path is left in `files/`, and it runs gitleaks. Review the diff, then commit. No sandbox calls it.

`files/zsh/zshrc`, `files/git/aliases.gitconfig` and `files/claude/statusline` are kept by hand.

## Check

```bash
sbx kit validate .
bash tests/check.sh
```

The check creates the sandbox `check-base` from `tests/sbxenv.yaml` and `check-base-nomkt` (a bogus marketplace)
from `tests/sbxenv-nomkt.yaml`. It asserts with `sbx exec`, stops and starts `check-base` three times, and removes
both sandboxes.
