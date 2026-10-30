FROM mikefarah/yq:4.47.2@sha256:76def1f56f456ecc1c3173ea275218ee17139bc2018c5a07887b15afd88ec03e AS yq

FROM alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

RUN apk add --no-cache \
        bash \
        bind-tools \
        clamav \
        coreutils \
        curl \
        iputils \
        openssl \
        sqlite \
        util-linux

COPY --from=yq /usr/bin/yq /usr/local/bin/yq
COPY service-watchdog.sh /opt/watchdog/service-watchdog.sh
COPY scripts/github-action-entrypoint.sh /usr/local/bin/watchdog-validate

RUN chmod 0555 /opt/watchdog/service-watchdog.sh /usr/local/bin/watchdog-validate

ENTRYPOINT ["/usr/local/bin/watchdog-validate"]
