# reMarkable Daily Journal Creator
# Automatically creates dated notebooks on your reMarkable tablet

# Fetch the prebuilt rmapi release binary (ddvk fork)
FROM alpine:3.19 AS rmapi-fetch
ARG TARGETARCH
ARG RMAPI_VERSION=v0.0.33
RUN apk add --no-cache curl tar && \
    case "${TARGETARCH:-amd64}" in \
      amd64) RMAPI_ARCH=amd64 ;; \
      arm64) RMAPI_ARCH=arm64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/rmapi.tar.gz \
      "https://github.com/ddvk/rmapi/releases/download/${RMAPI_VERSION}/rmapi-linux-${RMAPI_ARCH}.tar.gz" && \
    tar -xzf /tmp/rmapi.tar.gz -C /tmp && \
    install -m 0755 /tmp/rmapi /usr/local/bin/rmapi

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

# Copy rmapi binary from fetch stage
COPY --from=rmapi-fetch /usr/local/bin/rmapi /usr/local/bin/rmapi

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
