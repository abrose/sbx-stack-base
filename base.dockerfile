# syntax=docker/dockerfile:1
# Ships files/ read-only (root-owned) to /usr/local/share/sbx-stack in the VM.
FROM debian:trixie-slim AS build
COPY files/ /out/usr/local/share/sbx-stack/
RUN chmod -R u=rwX,go=rX /out && chmod 755 /out/usr/local/share/sbx-stack/claude/statusline
FROM scratch
COPY --from=build /out /
