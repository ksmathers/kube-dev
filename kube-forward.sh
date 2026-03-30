#!/bin/bash
set -euo pipefail
stslogin() {
    if [ -x "$(command -v arad-de)" ]; then
    . arad-de
    fi
}

stslogin
. setting.sh

NAMESPACE="${NAMESPACE:-default}"
LCUSER=`echo $USER | tr '[:upper:]' '[:lower:]'`
JOB_NAME="${APPNAME}-${LCUSER}"

echo "  NoVNC Shell:    http://localhost:7080/vnc.html?host=localhost&port=7080"
echo "  VS Code Server: http://localhost:23337"
echo "  JupyterLab:     http://localhost:9888"
echo ""
echo "To shut down:  kubectl delete job ${JOB_NAME} -n ${NAMESPACE}"
echo ""

# Auto-retry loop: STS tokens expire after ~1 hour, causing the port-forward
# to drop. Re-source credentials and reconnect automatically.
while true; do
    echo "[$(date '+%H:%M:%S')] Starting port-forward (Ctrl-C to stop)..."
    kubectl port-forward -n "${NAMESPACE}" \
        "job/${JOB_NAME}" \
        7080:6080 \
        23337:13337 \
        9888:8888 || true
    echo "[$(date '+%H:%M:%S')] Port-forward exited. Refreshing STS credentials and retrying in 5s..."
    sleep 5
    # Re-source credentials so the refreshed STS token is picked up
    stslogin
done
