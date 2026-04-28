. setting.sh

PLATFORM=linux/amd64
CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --arm) PLATFORM=linux/arm64 ;;
        --clean) CLEAN=1 ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

LCUSER=$(echo "$USER" | tr '[:upper:]' '[:lower:]')

# Stop any existing container bound to port 7080
EXISTING=$(docker ps -q --filter "publish=7080")
if [[ -n "$EXISTING" ]]; then
    echo "Stopping existing container on port 7080..."
    docker stop $EXISTING
fi

mkdir -p "dev-home-${LCUSER}"
if [[ "${CLEAN}" -eq 1 ]]; then
    echo "[--clean] Removing dev-home-${LCUSER}..."
    rm -rf "dev-home-${LCUSER}"
    mkdir -p "dev-home-${LCUSER}"
fi
CONTAINER_ID=$(docker run -d --rm --platform="${PLATFORM}" --shm-size=512m -p7080:6080 \
  -v "dev-home-${LCUSER}:/home/dev" \
  ${APPNAME}:${VERSION})
echo "Container started: ${CONTAINER_ID}"

echo "Waiting for NoVNC to be ready..."
for i in $(seq 1 60); do
    if curl -sf http://localhost:7080/vnc.html > /dev/null 2>&1; then
        echo "NoVNC is ready."
        break
    fi
    if ! docker inspect -f '{{.State.Running}}' "${CONTAINER_ID}" > /dev/null 2>&1; then
        echo "ERROR: Container exited unexpectedly."
        docker logs "${CONTAINER_ID}" 2>/dev/null || true
        exit 1
    fi
    echo "  waiting... (${i}/60)"
    sleep 2
done
if ! curl -sf http://localhost:7080/vnc.html > /dev/null 2>&1; then
    echo "ERROR: NoVNC did not become ready in time."
    exit 1
fi

echo "To access the application in the browser navigate to:"
echo "  NoVNC Shell: http://localhost:7080/vnc.html?host=localhost&port=7080"