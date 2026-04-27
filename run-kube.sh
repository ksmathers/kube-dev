#!/bin/bash
set -euo pipefail
. setting.sh
. $HOME/.docker-repository.sh

NAMESPACE="${NAMESPACE:-default}"
LCUSER=`echo $USER | tr '[:upper:]' '[:lower:]'`
PVC_NAME="dev-workspace-pvc-${LCUSER}"
DEPLOY_NAME="dev-environment-${LCUSER}"
IMAGE="${APPNAME}:${VERSION}"
STORAGE="100Gi"

# ── T-shirt sizes (AWS general-purpose memory convention) ────────────────────
#   small    1 vCPU   2 GiB
#   medium   2 vCPU   4 GiB
#   large    2 vCPU   8 GiB   (default)
#   xlarge   4 vCPU  16 GiB
#   2xlarge  8 vCPU  32 GiB
#   4xlarge 16 vCPU  64 GiB
apply_size() {
    case "$1" in
        small)   CPU_REQUEST="1";  CPU_LIMIT="1";  MEMORY_REQUEST="2Gi";  MEMORY_LIMIT="2Gi"  ;;
        medium)  CPU_REQUEST="1";  CPU_LIMIT="2";  MEMORY_REQUEST="4Gi";  MEMORY_LIMIT="4Gi"  ;;
        large)   CPU_REQUEST="2";  CPU_LIMIT="2";  MEMORY_REQUEST="8Gi";  MEMORY_LIMIT="8Gi"  ;;
        xlarge)  CPU_REQUEST="4";  CPU_LIMIT="4";  MEMORY_REQUEST="16Gi"; MEMORY_LIMIT="16Gi" ;;
        2xlarge) CPU_REQUEST="8";  CPU_LIMIT="8";  MEMORY_REQUEST="32Gi"; MEMORY_LIMIT="32Gi" ;;
        4xlarge) CPU_REQUEST="16"; CPU_LIMIT="16"; MEMORY_REQUEST="64Gi"; MEMORY_LIMIT="64Gi" ;;
        *) echo "ERROR: Unknown size '$1'. Valid sizes: small, medium, large, xlarge, 2xlarge, 4xlarge"; exit 1 ;;
    esac
}
SIZE="${SIZE:-large}"
apply_size "${SIZE}"
echo "Size: ${SIZE}  (CPU ${CPU_REQUEST}, RAM ${MEMORY_REQUEST})"

PUSH_IMAGE=0
CLEAN=0
BUILD_IMAGE=0
for arg in "$@"; do
    case "$arg" in
        --push) PUSH_IMAGE=1 ;;
        --build) BUILD_IMAGE=1 ;;
        --build-push) BUILD_IMAGE=1; PUSH_IMAGE=1 ;;
        --clean) CLEAN=1 ;;
        --size=*) SIZE="${arg#--size=}"
            apply_size "${SIZE}"
            echo "Size override: ${SIZE}  (CPU ${CPU_REQUEST}, RAM ${MEMORY_REQUEST})"
            ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

JOB_NAME="${APPNAME}-${LCUSER}"

# -- 0. Build and/or push image -----------------------------------------------

if [ "${BUILD_IMAGE}" -eq 1 ]; then
    echo "Building image..."
    bash "$(dirname "$0")/build.sh"
fi

push_image() {
    echo "Pushing image: ${REPOSITORY_TAG}..."
    docker tag "${IMAGE}" "${REPOSITORY_TAG}"
    if [ "${ECR_LOGIN}" -eq 1 ]; then
        echo "Logging in to ECR..."
        aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin ${REPOSITORY_HOST} >/dev/null
    fi
    docker push "${REPOSITORY_TAG}"
}

if [ "${PUSH_IMAGE}" -eq 1 ]; then
    push_image
else
    echo "Skipping image push. Use --push to push the image to ${REPOSITORY_TAG}."
fi

# ── 1. PersistentVolumeClaim ──────────────────────────────────────────────────
if [[ "${CLEAN}" -eq 1 ]]; then
    if kubectl get job "${JOB_NAME}" -n "${NAMESPACE}" &>/dev/null; then
        echo "[--clean] Deleting existing Job '${JOB_NAME}'..."
        kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --wait=true
    fi
    if kubectl get pvc "${PVC_NAME}" -n "${NAMESPACE}" &>/dev/null; then
        echo "[--clean] Deleting PersistentVolumeClaim '${PVC_NAME}'..."
        kubectl delete pvc "${PVC_NAME}" -n "${NAMESPACE}" --wait=true
    fi
fi
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
# Delete any existing job first (Jobs are immutable once created)
if kubectl get job "${JOB_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    echo "Deleting existing Job '${JOB_NAME}'..."
    kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --wait=true
fi
echo "Creating Job '${JOB_NAME}' (image: ${REPOSITORY_TAG}, memory: ${MEMORY_LIMIT})..."
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
          image: ${REPOSITORY_TAG}
          imagePullPolicy: IfNotPresent
          env:
            - name: NOVNC_PORT
              value: "6080"
            - name: VNC_PORT
              value: "5901"
          ports:
            - name: novnc
              containerPort: 6080
          volumeMounts:
            - name: workspace
              mountPath: /home/dev
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
