# kube-dev — Kubernetes Dev Environment

A self-contained browser-based development environment that runs inside a Kubernetes cluster. It provides:

| Service | URL (via port-forward) | Port |
|---|---|---|
| **NoVNC** (full desktop in browser) | `http://localhost:6080` | 6080 |
| **VS Code** (code-server) | `http://localhost:13337` | 13337 |
| **JupyterLab** | `http://localhost:8888` | 8888 |

Google Chrome is installed inside the desktop environment and can be launched from the noVNC session.

The container also ships **git**, **sudo**, and **micromamba** pre-configured for the **conda-forge** channel.

---

## Repository layout

```
kube-dev/
├── Dockerfile             # Container image definition
├── start-dev-env.sh       # Entrypoint: starts Xvfb, Fluxbox, x11vnc, noVNC, code-server
├── dev-environment.yaml   # Kubernetes PVC + Deployment + Service
└── README.md
```

---

## Prerequisites

- Docker (or any OCI-compatible builder) for building the image
- A container registry you can push to (e.g. GitHub Container Registry, Docker Hub)
- A running Kubernetes cluster and `kubectl` configured
- *(Optional)* `kubectl` port-forward access to the pod

---

## 1. Build and push the image

```bash
IMAGE=ghcr.io/your-org/dev-novnc-vscode:latest

docker build -t "$IMAGE" .
docker push "$IMAGE"
```

Update the `image:` field in `dev-environment.yaml` to match your registry path.

---

## 2. Deploy to Kubernetes

The manifests intentionally omit a `namespace` field so you can target any namespace at deploy time.

```bash
# Create the namespace if it doesn't already exist
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -

# Deploy everything
kubectl apply -n dev -f dev-environment.yaml
```

This creates:

| Resource | Name | Purpose |
|---|---|---|
| `PersistentVolumeClaim` | `dev-workspace-pvc` | 20 Gi volume mounted at `/workspace` |
| `Deployment` | `dev-environment` | Single pod running the dev environment |
| `Service` (ClusterIP) | `dev-environment` | Internal cluster access on ports 6080 and 13337 |

Wait for the pod to be ready:

```bash
kubectl wait --for=condition=Ready pod -l app=dev-environment -n dev --timeout=120s
```

---

## 3. Access the environment

Use `kubectl port-forward` to reach the services from your local machine:

```bash
kubectl port-forward -n dev svc/dev-environment 6080:6080 13337:13337 8888:8888
```

Then open your browser:

- **Desktop (noVNC):** http://localhost:6080
- **VS Code:** http://localhost:13337
- **JupyterLab:** http://localhost:8888

> None of the services require authentication by default. See the [Security](#security) section below before exposing them outside the cluster.

---

## 4. Using conda-forge / micromamba

`micromamba` is installed at `/usr/local/bin/micromamba` and the `base` environment (Python 3.12) is pre-activated. The default channel is `conda-forge`. **JupyterLab and Notebook are pre-installed** in the `base` environment.

Open a terminal inside VS Code or the noVNC desktop and run:

```bash
# Install a package into the base environment
micromamba install -n base numpy pandas scikit-learn

# Create a new environment and register it as a Jupyter kernel
micromamba create -n myproject python=3.11 scipy ipykernel
micromamba run -n myproject python -m ipykernel install --user --name myproject
```

The `~/.condarc` (written to `/etc/conda/.condarc` in the image) is:

```yaml
channels:
  - conda-forge
channel_priority: strict
```

---

## 5. Using git

`git` is installed and available system-wide. Configure it for the `dev` user inside the container:

```bash
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```

Clone repositories into `/workspace`, which is backed by the persistent volume.

---

## 6. Sudo access

The `dev` user has **passwordless sudo**. To run a command as root:

```bash
sudo apt-get install -y some-package
```

---

## Environment variables

These can be overridden in `dev-environment.yaml` under `env:`:

| Variable | Default | Description |
|---|---|---|
| `NOVNC_PORT` | `6080` | Port the noVNC proxy listens on |
| `VNC_PORT` | `5901` | Internal VNC port (not exposed externally) |
| `CODE_SERVER_PORT` | `13337` | Port code-server listens on |
| `JUPYTER_PORT` | `8888` | Port JupyterLab listens on |

---

## Resource limits

Default requests/limits defined in the Deployment:

| | CPU | Memory |
|---|---|---|
| **Request** | 500m | 1 Gi |
| **Limit** | 2 | 4 Gi |

Adjust these in `dev-environment.yaml` to match your cluster's capacity.

---

## Teardown

```bash
kubectl delete -n dev -f dev-environment.yaml
```

> The `PersistentVolumeClaim` is deleted by the command above. If you want to keep your workspace data, remove the PVC from the command or patch the `persistentVolumeReclaimPolicy` of the underlying `PersistentVolume` to `Retain` before deleting.

---

## Security

This image is designed for **internal / trusted cluster use only**:

- code-server runs with `--auth none`
- x11vnc runs with no VNC password (`-nopw`)
- JupyterLab runs with no token and no password (`--NotebookApp.token=''`)
- The `dev` user has passwordless `sudo`

Before exposing the services outside the cluster, consider:

- Enabling code-server's built-in password or OAuth proxy (`--auth password` / `oauth2-proxy`)
- Adding a VNC password via `x11vnc -passwd`
- Setting a Jupyter token via the `JUPYTER_TOKEN` env var or using `jupyter_server_config.py`
- Wrapping the Service in an `Ingress` with TLS and authentication
- Running the pod in a dedicated namespace with appropriate `NetworkPolicy` rules
