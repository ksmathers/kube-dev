#!/bin/bash
. setting.sh
PLATFORM=linux/amd64
WITH_CA=0
for arg in "$@"; do
    case "$arg" in
        --with-ca) WITH_CA=1 ;;
        --arm) PLATFORM=linux/arm64 ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done
export DOCKER_DEFAULT_PLATFORM="$PLATFORM"

BUILD_ARGS=()
if [[ $WITH_CA -eq 1 ]]; then
    CA_SRC="${HOME}/etc/CombinedCA.cer"
    CA_DEST="CombinedCA.cer"
    if [[ ! -f "$CA_SRC" ]]; then
        echo "Error: CA file not found at $CA_SRC"
        exit 1
    fi
    cp "$CA_SRC" "$CA_DEST"
    BUILD_ARGS+=(--build-arg WITH_CA=1)
    echo "Copied $CA_SRC into build context."
else
    # Create a placeholder so the Dockerfile COPY instruction always succeeds
    touch CombinedCA.cer
fi

docker build "${BUILD_ARGS[@]}" -t ${APPNAME}:${VERSION} .
docker tag ${APPNAME}:${VERSION} ${APPNAME}:latest
echo "Built image: ${APPNAME}:${VERSION}"

# Clean up the CA cert copy from the build context
if [[ $WITH_CA -eq 1 ]]; then
    rm -f CombinedCA.cer
fi