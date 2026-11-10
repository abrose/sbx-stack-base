# sbx-stack-base

The base image of sbx-stack: the owner's personal setup for Docker Sandboxes (sbx), built from a Dockerfile and
loaded into sbx as the template `sbx-stack-base:<VERSION>`. Every project file names it as its template. Project
layers (node, gitlab, ...) stay kits in the project file.

The design is `docs/specs/2026-11-10-sbx-stack-base-image-design.md` in `sbx-kit-builder`.

## Source of truth

This repo holds every file and every pinned version of the image. The configs in `files/` started as a one-time
seed from the owner's dotfiles (zsh, LazyVim, yazi) and are kept here by hand from now on. Nothing is copied from
the Mac at build time, except the git `user.name` and `user.email`.

## Files

| Path | What |
|---|---|
| `VERSION` | the image version |
| `apt-packages.txt` | the Debian packages, one per line |
| `files/zsh/zshrc` | the zsh config, sourced from `/etc/zsh/zshrc` |
| `files/starship.toml`, `files/git/` | the prompt and the git aliases |
| `files/nvim/` | the LazyVim config, to `~/.config/nvim` |
| `files/yazi/` | the yazi config, to `~/.config/yazi` |
| `files/claude/` | `managed-settings.json` (to `/etc/claude-code/`), the statusline and the safety hooks |
| `tests/seed.sh` | static checks of the files |
