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

JOB_NAME="dev-environment-$(echo "$USER" | tr '[:upper:]' '[:lower:]')"

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

# ── 2. Job ───────────────────────────────────────────────────────────────────
echo "Creating Job '${JOB_NAME}' (image: ${ECR_REPO}, memory: ${MEMORY_LIMIT})..."
kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  labels:
    app: ${DEPLOY_NAME}
spec:
  ttlSecondsAfterFinished: 60
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: ${DEPLOY_NAME}
        job-name: ${JOB_NAME}
    spec:
      restartPolicy: Never
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

# ── 3. Wait for the Job pod to reach Running ──────────────────────────────────
echo "Waiting for Job pod to start running..."
for i in $(seq 1 60); do
    POD_NAME=$(kubectl get pod -n "${NAMESPACE}" -l "job-name=${JOB_NAME}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "${POD_NAME}" ]]; then
        echo "Pod is running: ${POD_NAME}"
        break
    fi
    echo "  waiting for pod... (${i}/60)"
    sleep 2
done
if [[ -z "${POD_NAME:-}" ]]; then
    echo "ERROR: Pod did not reach Running state in time."
    kubectl describe job "${JOB_NAME}" -n "${NAMESPACE}"
    exit 1
fi

# ── 4. Confirm noVNC is actually responding inside the pod ───────────────────
echo "Confirming noVNC service is up inside the pod..."
for i in $(seq 1 30); do
    if kubectl exec -n "${NAMESPACE}" "job/${JOB_NAME}" -- \
            bash -c 'exec 3<>/dev/tcp/127.0.0.1/6080' 2>/dev/null; then
        echo "noVNC is ready."
        break
    fi
    echo "  waiting for noVNC... (${i}/30)"
    sleep 2
done

echo "Job '${JOB_NAME}' is ready. Run ./kube-forward.sh to connect."
