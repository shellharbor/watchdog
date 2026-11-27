# CI-only SDK builder. Root is required by the upstream compiler toolchain;
# it is not a deployment image and must never be published as Watchdog runtime.
FROM mikefarah/yq:4.54.1@sha256:4b3d9475d65571d28cbb19544d3820ec2945e4c8b2f18279394282b8dc3a592e AS yq
FROM gcr.io/oss-fuzz-base/base-builder-python@sha256:0aa4f12ee4e9a4aaa1e511b3ded82d662475150b82a786478f22d5c41adbacbd

COPY --from=yq /usr/bin/yq /usr/local/bin/yq
COPY service-watchdog.sh VERSION /src/watchdog/
COPY lib/watchdog /src/watchdog/lib/watchdog/
COPY .clusterfuzzlite /src/watchdog/.clusterfuzzlite/
COPY .clusterfuzzlite/build.sh /src/build.sh
WORKDIR /src/watchdog
