# reMarkable Daily Journal Creator
# Automatically creates dated notebooks on your reMarkable tablet

# Build rmapi from source at a pinned tag (ddvk fork).
# Static build (CGO_ENABLED=0) so the binary runs on the alpine/musl runtime.
# The official release tarballs are glibc-linked and will not execute on alpine.
FROM golang:1.23-alpine AS builder
ARG RMAPI_VERSION=v0.0.33
RUN apk add --no-cache git && \
    git clone --depth 1 --branch ${RMAPI_VERSION} https://github.com/ddvk/rmapi.git /src/rmapi && \
    cd /src/rmapi && \
    CGO_ENABLED=0 go build \
      -ldflags "-s -w -X github.com/juruen/rmapi/version.Version=${RMAPI_VERSION}" \
      -o /go/bin/rmapi .

# Runtime image
FROM alpine:3.19

# User/group configuration (can be overridden at build time)
ARG PUID=1000
ARG PGID=1000

# Install dependencies
# Note: crond is included in busybox (part of Alpine base)
RUN apk add --no-cache \
    bash \
    tzdata \
    ghostscript \
    unzip

# Copy rmapi binary from builder
COPY --from=builder /go/bin/rmapi /usr/local/bin/rmapi

# Create app user with configurable UID/GID
RUN addgroup -g ${PGID} app && \
    adduser -D -h /app -u ${PUID} -G app app

# Store UID/GID for runtime reference
ENV PUID=${PUID} PGID=${PGID}

WORKDIR /app

# Copy scripts
COPY create-daily-note.sh /app/
COPY cleanup-old-journals.sh /app/
COPY entrypoint.sh /app/
RUN chmod +x /app/*.sh

# Config volume for rmapi authentication
VOLUME /app/.config/rmapi

# Switch to app user
USER app

ENTRYPOINT ["/app/entrypoint.sh"]
