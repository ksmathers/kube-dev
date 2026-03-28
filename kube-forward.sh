#!/bin/bash
set -euo pipefail
. arad-de
. setting.sh

NAMESPACE="${NAMESPACE:-default}"
JOB_NAME="dev-environment-$(echo "$USER" | tr '[:upper:]' '[:lower:]')"

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
    echo "[$(date '+%H:%M:%S')] Port-forward exited. Re-sourcing credentials and retrying in 5s..."
    sleep 5
    # Re-source credentials so the refreshed STS token is picked up
    . arad-de
done
