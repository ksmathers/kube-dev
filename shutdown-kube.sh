#!/bin/bash
set -euo pipefail
. arad-de
. setting.sh

NAMESPACE="${NAMESPACE:-default}"
JOB_NAME="dev-environment-$(echo "$USER" | tr '[:upper:]' '[:lower:]')"

echo "Deleting job '${JOB_NAME}' in namespace '${NAMESPACE}'..."
kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found
echo "Done. (PVC '${APPNAME}-workspace-pvc' retained.)"