. arad-de
. setting.sh

NAMESPACE="${NAMESPACE:-default}"
SVC_NAME="dev-environment"

# ── 5. Port-forward ───────────────────────────────────────────────────────────
echo ""
echo "Starting port-forward (Ctrl-C to stop)..."
echo "  NoVNC Shell:    http://localhost:7080/vnc.html?host=localhost&port=7080"
echo "  VS Code Server: http://localhost:23337"
echo "  JupyterLab:     http://localhost:9888"
echo ""
kubectl port-forward -n "${NAMESPACE}" \
    "svc/${SVC_NAME}" \
    7080:6080 \
    23337:13337 \
    9888:8888
