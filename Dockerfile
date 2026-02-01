# reMarkable Daily Journal Creator
# Automatically creates dated notebooks on your reMarkable tablet

FROM golang:1.21-alpine AS builder

# Install git for go install
RUN apk add --no-cache git

# Build rmapi from source (ddvk fork)
RUN go install github.com/ddvk/rmapi@latest

# Runtime image
FROM alpine:3.19

# Install dependencies
RUN apk add --no-cache \
    bash \
    tzdata \
    ghostscript \
    supercrond

# Copy rmapi binary from builder
COPY --from=builder /go/bin/rmapi /usr/local/bin/rmapi

# Create app user
RUN adduser -D -h /app app
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
