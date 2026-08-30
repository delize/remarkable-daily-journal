# reMarkable Daily Journal Creator
# Automatically creates dated notebooks on your reMarkable tablet

# Build rmapi from source (ddvk fork).
# Static build (CGO_ENABLED=0) so the binary runs on the alpine/musl runtime.
# The official release tarballs are glibc-linked and will not execute on alpine.
#
# Do NOT drop below v0.0.35. Everything older predates reMarkable's 2025/2026
# cloud sync API changes and fails in two distinct ways, both reported as a
# 400 so they are easy to confuse:
#   * v0.0.34 (May 2024) and earlier: "failed to mirror was not ok: request
#     failed with status 400" on any sync. Fixed by ddvk/rmapi #57, #62, #67.
#   * anything before v0.0.35: the cloud rejects root index uploads whose
#     entries are not sorted by document ID, with
#     400 {"message":"invalid root schema"} (ddvk/rmapi #75, #76). READS are
#     unaffected, so `rmapi ls` looks healthy while every `put` and `rm`
#     fails — which means the health check passes and journal creation still
#     does not work. Fixed by ddvk/rmapi #77.
# v0.0.35 also carries the `-json` output flag that cleanup-old-journals.sh
# needs to read the whole folder's metadata in a single call.
FROM golang:1.27-alpine AS builder
# Pinned by commit SHA rather than tag name so the checkout is immutable even
# if a tag is ever moved. This SHA is the v0.0.35 tag (2026-08-19). Bump
# deliberately (e.g. when ddvk publishes a fix or chases a cloud-API change)
# rather than tracking master, so the image isn't subject to surprise upstream
# changes between builds.
ARG RMAPI_VERSION=74a8e2ec7f324655ef3a3890936ed78e6e13ee51
RUN apk add --no-cache git
WORKDIR /src/rmapi
RUN git clone https://github.com/ddvk/rmapi.git . && \
    git checkout --quiet ${RMAPI_VERSION} && \
    CGO_ENABLED=0 go build \
      -ldflags "-s -w -X github.com/juruen/rmapi/version.Version=${RMAPI_VERSION}" \
      -o /go/bin/rmapi .

# Runtime image
FROM alpine:3.24

# User/group configuration (can be overridden at build time)
ARG PUID=1000
ARG PGID=1000

# Install dependencies
# Note: crond is included in busybox (part of Alpine base)
# `apk upgrade` pulls patched packages (e.g. libcrypto3/libssl3) on top of the
# base image, which can ship stale versions between Alpine point releases.
# qpdf is optional at runtime (only used for a cosmetic page count in the
# experimental TEMPLATE_PDF_NATIVE_EXPERIMENTAL variant); kept installed
# since it's small and has zero known CVEs. py3-img2pdf wraps a PNG/JPG
# TEMPLATE_PDF into a PDF.
RUN apk update && apk upgrade --no-cache && \
    apk add --no-cache \
    bash \
    tzdata \
    unzip \
    zip \
    curl \
    jq \
    qpdf \
    py3-img2pdf \
    ca-certificates

# Copy rmapi binary from builder
COPY --from=builder /go/bin/rmapi /usr/local/bin/rmapi

# Create app user with configurable UID/GID
RUN addgroup -g ${PGID} app && \
    adduser -D -h /app -u ${PUID} -G app app

# Store UID/GID for runtime reference
ENV PUID=${PUID} PGID=${PGID}

WORKDIR /app

# Copy scripts and native-notebook assets (blank .rm stencil + base .content)
COPY create-daily-note.sh /app/
COPY generate-native-journal.sh /app/
COPY cleanup-old-journals.sh /app/
COPY rmapi-health.sh /app/
COPY github-notify.sh /app/
COPY entrypoint.sh /app/
COPY assets/ /app/assets/
COPY scripts/ /app/scripts/
RUN chmod +x /app/*.sh /app/scripts/*.sh

# Config volume for rmapi authentication
VOLUME /app/.config/rmapi

# Optional: bind-mount custom PDF templates here and point TEMPLATE_PDF at a
# file inside it, e.g. TEMPLATE_PDF=/app/templates/planner.pdf
VOLUME /app/templates

# Switch to app user
USER app

ENTRYPOINT ["/app/entrypoint.sh"]
