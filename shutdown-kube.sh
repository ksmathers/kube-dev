. setting.sh

NAMESPACE="${NAMESPACE:-default}"

. arad-de
kubectl delete deployment dev-environment -n "${NAMESPACE}" --ignore-not-found
kubectl delete svc dev-environment -n "${NAMESPACE}" --ignore-not-found