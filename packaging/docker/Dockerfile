FROM mikefarah/yq:4.47.2@sha256:76def1f56f456ecc1c3173ea275218ee17139bc2018c5a07887b15afd88ec03e AS yq

FROM alpine:3.21@sha256:ce64758a109eb420d874a118f87920e625e12d3634e03b4a5573fd9f6e5d3507 AS runtime

ARG VERSION=dev
ARG REVISION=unknown

LABEL org.opencontainers.image.title="ShellHarbor Watchdog" \
      org.opencontainers.image.description="One-shot Bash service monitor for scheduled container runs." \
      org.opencontainers.image.url="https://github.com/shellharbor/watchdog" \
      org.opencontainers.image.source="https://github.com/shellharbor/watchdog" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

RUN apk add --no-cache \
        bash \
        bind-tools \
        ca-certificates \
        clamav \
        coreutils \
        curl \
        findutils \
        gawk \
        grep \
        iputils \
        openssl \
        sqlite \
        tzdata \
        util-linux \
    && addgroup -S -g 10001 watchdog \
    && adduser -S -D -H -u 10001 -G watchdog watchdog \
    && install -d -m 0750 -o watchdog -g watchdog /var/lib/watchdog

COPY --from=yq /usr/bin/yq /usr/local/bin/yq
COPY service-watchdog.sh VERSION /opt/watchdog/
COPY packaging/docker/entrypoint.sh /usr/local/bin/watchdog-container

RUN chmod 0555 /opt/watchdog/service-watchdog.sh /usr/local/bin/watchdog-container

USER 10001:10001
WORKDIR /opt/watchdog

ENTRYPOINT ["/usr/local/bin/watchdog-container"]
CMD []

# This verifies Watchdog's own configuration and dependencies. It deliberately
# does not report whether monitored targets are healthy; the one-shot command's
# exit status is the authoritative monitoring result.
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/watchdog-container", "healthcheck"]

FROM runtime AS docker

USER root
RUN apk add --no-cache docker-cli docker-cli-compose
USER 10001:10001
