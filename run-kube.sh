#!/bin/bash
set -euo pipefail
. setting.sh

NAMESPACE="${NAMESPACE:-default}"
PVC_NAME="dev-workspace-pvc"
DEPLOY_NAME="dev-environment"
SVC_NAME="dev-environment"
IMAGE="${APPNAME}:${VERSION}"
STORAGE="100Gi"
MEMORY_REQUEST="32Gi"
MEMORY_LIMIT="32Gi"
CPU_REQUEST="2"
CPU_LIMIT="4"

ECR_PUSH=0
for arg in "$@"; do
    case "$arg" in
        --push-ecr) ECR_PUSH=1 ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# -- 0. Push image to ECR ------------------------------------------------------

push_ecr() {
    echo "Pushing image to ECR: ${ECR_REPO}..."
    docker tag "${IMAGE}" "${ECR_REPO}"
    aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin ${ECR_HOST} >/dev/null
    docker push "${ECR_REPO}"
}
if [ "${ECR_PUSH}" -eq 1 ]; then
    push_ecr
fi

# ── 1. PersistentVolumeClaim ──────────────────────────────────────────────────
echo "Applying PersistentVolumeClaim '${PVC_NAME}' (${STORAGE})..."
kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${STORAGE}
EOF

# ── 2. Deployment ─────────────────────────────────────────────────────────────
echo "Applying Deployment '${DEPLOY_NAME}' (image: ${IMAGE}, memory: ${MEMORY_LIMIT})..."
kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_NAME}
  labels:
    app: ${DEPLOY_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${DEPLOY_NAME}
  template:
    metadata:
      labels:
        app: ${DEPLOY_NAME}
    spec:
      containers:
        - name: ${DEPLOY_NAME}
          image: ${ECR_REPO}
          imagePullPolicy: IfNotPresent
          env:
            - name: NOVNC_PORT
              value: "6080"
            - name: CODE_SERVER_PORT
              value: "13337"
            - name: VNC_PORT
              value: "5901"
            - name: JUPYTER_PORT
              value: "8888"
          ports:
            - name: novnc
              containerPort: 6080
            - name: vscode
              containerPort: 13337
            - name: jupyter
              containerPort: 8888
          readinessProbe:
            tcpSocket:
              port: novnc
            initialDelaySeconds: 15
            periodSeconds: 5
            failureThreshold: 12
          livenessProbe:
            tcpSocket:
              port: novnc
            initialDelaySeconds: 30
            periodSeconds: 10
          volumeMounts:
            - name: workspace
              mountPath: /workspace
          resources:
            requests:
              cpu: "${CPU_REQUEST}"
              memory: "${MEMORY_REQUEST}"
            limits:
              cpu: "${CPU_LIMIT}"
              memory: "${MEMORY_LIMIT}"
      volumes:
        - name: workspace
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
EOF

# ── 3. Service ────────────────────────────────────────────────────────────────
echo "Applying Service '${SVC_NAME}'..."
kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${SVC_NAME}
  labels:
    app: ${DEPLOY_NAME}
spec:
  selector:
    app: ${DEPLOY_NAME}
  type: ClusterIP
  ports:
    - name: novnc
      port: 6080
      targetPort: novnc
    - name: vscode
      port: 13337
      targetPort: vscode
    - name: jupyter
      port: 8888
      targetPort: jupyter
EOF

# ── 4. Wait for pod to be ready ───────────────────────────────────────────────
echo "Waiting for deployment '${DEPLOY_NAME}' to become ready..."
kubectl rollout status deployment/"${DEPLOY_NAME}" -n "${NAMESPACE}" --timeout=300s

# ── 4b. Confirm noVNC is actually responding inside the pod ──────────────────
echo "Confirming noVNC service is up inside the pod..."
POD_NAME=$(kubectl get pod -n "${NAMESPACE}" -l app="${DEPLOY_NAME}" \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
for i in $(seq 1 30); do
    if kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- \
            bash -c 'exec 3<>/dev/tcp/127.0.0.1/6080' 2>/dev/null; then
        echo "noVNC is ready."
        break
    fi
    echo "  waiting for noVNC... (${i}/30)"
    sleep 2
done

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
