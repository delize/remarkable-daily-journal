# reMarkable Daily Journal Creator
# Automatically creates dated notebooks on your reMarkable tablet

# Build rmapi from source (ddvk fork).
# Static build (CGO_ENABLED=0) so the binary runs on the alpine/musl runtime.
# The official release tarballs are glibc-linked and will not execute on alpine.
#
# Build from `master`, NOT a release tag: the newest tag (v0.0.34) is from
# May 2024 and predates reMarkable's 2025/2026 cloud sync API change. That
# change makes older rmapi fail with "failed to mirror was not ok: request
# failed with status 400". The fixes (ddvk/rmapi #57, #62, #67) only exist on
# master, untagged. Override RMAPI_VERSION with a commit SHA to pin for
# reproducibility once a known-good commit is identified.
FROM golang:1.23-alpine AS builder
# Pinned to a known-good ddvk/rmapi commit for reproducibility. Bump
# deliberately (e.g. when ddvk publishes a fix or chases a cloud-API change)
# rather than tracking master, so the image isn't subject to surprise upstream
# changes between builds.
ARG RMAPI_VERSION=434da60d178dd04e0659fb502ea1251600c5d6ef
RUN apk add --no-cache git
WORKDIR /src/rmapi
RUN git clone https://github.com/ddvk/rmapi.git . && \
    git checkout --quiet ${RMAPI_VERSION} && \
    CGO_ENABLED=0 go build \
      -ldflags "-s -w -X github.com/juruen/rmapi/version.Version=${RMAPI_VERSION}" \
      -o /go/bin/rmapi .

# Runtime image
FROM alpine:3.23

# User/group configuration (can be overridden at build time)
ARG PUID=1000
ARG PGID=1000

# Install dependencies
# Note: crond is included in busybox (part of Alpine base)
RUN apk add --no-cache \
    bash \
    tzdata \
    unzip \
    zip \
    curl \
    jq \
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
COPY github-notify.sh /app/
COPY entrypoint.sh /app/
COPY assets/ /app/assets/
COPY scripts/ /app/scripts/
RUN chmod +x /app/*.sh /app/scripts/*.sh

# Config volume for rmapi authentication
VOLUME /app/.config/rmapi

# Switch to app user
USER app

ENTRYPOINT ["/app/entrypoint.sh"]
