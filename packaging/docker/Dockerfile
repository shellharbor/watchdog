FROM mikefarah/yq:4.54.1@sha256:4b3d9475d65571d28cbb19544d3820ec2945e4c8b2f18279394282b8dc3a592e AS yq

FROM alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a AS runtime

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
