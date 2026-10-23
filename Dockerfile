FROM mikefarah/yq:4.54.1@sha256:4b3d9475d65571d28cbb19544d3820ec2945e4c8b2f18279394282b8dc3a592e AS yq

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
