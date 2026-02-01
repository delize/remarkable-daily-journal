# reMarkable Daily Journal Creator
# Automatically creates dated notebooks on your reMarkable tablet

FROM golang:1.23-alpine AS builder

# Install git for cloning
RUN apk add --no-cache git

# Clone and build rmapi from source (ddvk fork)
# Using git clone + go build because go.mod has replace directives
RUN git clone --depth 1 https://github.com/ddvk/rmapi.git /src/rmapi && \
    cd /src/rmapi && \
    go build -o /go/bin/rmapi .

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
    ghostscript

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
