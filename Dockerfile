FROM mikefarah/yq:4.47.2@sha256:76def1f56f456ecc1c3173ea275218ee17139bc2018c5a07887b15afd88ec03e AS yq

FROM alpine:3.21@sha256:ce64758a109eb420d874a118f87920e625e12d3634e03b4a5573fd9f6e5d3507

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
