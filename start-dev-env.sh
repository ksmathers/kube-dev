#!/usr/bin/env bash
# Do NOT use set -e here: background service scripts routinely return non-zero
# during startup (e.g. x11vnc -bg parent exits 1). Use explicit error handling.
set -uo pipefail

export DISPLAY=:1
export VNC_PORT="${VNC_PORT:-5901}"
export NOVNC_PORT="${NOVNC_PORT:-6080}"
export CODE_SERVER_PORT="${CODE_SERVER_PORT:-13337}"
export JUPYTER_PORT="${JUPYTER_PORT:-8888}"

mkdir -p /workspace
chown -R dev:dev /workspace /home/dev /opt/conda || true

# Pre-create X11 socket dir as root; Xvfb requires it with sticky-bit perms.
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

# ── X virtual display ────────────────────────────────────────────────────────
# -ac  : disable access control so the dev user can connect without xauth
echo "[startup] starting Xvfb..."
Xvfb :1 -screen 0 1920x1080x24 -nolisten tcp -ac &

# Wait until the X socket appears (up to 10 s)
for i in $(seq 1 20); do
  [ -S /tmp/.X11-unix/X1 ] && break
  sleep 0.5
done
echo "[startup] Xvfb ready"

# ── Window manager ───────────────────────────────────────────────────────────
# Load xterm colours, set wallpaper, then exec fluxbox (replaces this shell)
su - dev -c "DISPLAY=:1 bash -c '
  xrdb -merge \$HOME/.Xresources 2>/dev/null
  feh --bg-fill /usr/share/pixmaps/wallpaper.png
  exec fluxbox
'" &

# ── VNC server ───────────────────────────────────────────────────────────────
# -noshm : disable MIT-SHM; required in containers (no shared memory access)
# Run as a bash background job (not x11vnc -bg) to avoid su returning exit 1
echo "[startup] starting x11vnc..."
su - dev -c "x11vnc -display :1 -forever -shared -rfbport ${VNC_PORT} -nopw -noshm" &

# Wait until x11vnc is actually listening (up to 15 s)
for i in $(seq 1 30); do
  bash -c "exec 3<>/dev/tcp/127.0.0.1/${VNC_PORT}" 2>/dev/null && break
  sleep 0.5
done
echo "[startup] x11vnc ready on :${VNC_PORT}"

# ── noVNC / websockify ───────────────────────────────────────────────────────
echo "[startup] starting websockify on :${NOVNC_PORT} -> 127.0.0.1:${VNC_PORT}"
websockify --web /usr/share/novnc 0.0.0.0:${NOVNC_PORT} 127.0.0.1:${VNC_PORT} &

# ── VS Code (code-server) ────────────────────────────────────────────────────
echo "[startup] starting code-server on :${CODE_SERVER_PORT}"
su - dev -c "code-server --bind-addr 0.0.0.0:${CODE_SERVER_PORT} --auth none /workspace" &

# ── JupyterLab ───────────────────────────────────────────────────────────────
echo "[startup] starting JupyterLab on :${JUPYTER_PORT}"
su - dev -c "
  export PATH=/opt/conda/bin:\$PATH
  jupyter lab \
    --ip=0.0.0.0 \
    --port=${JUPYTER_PORT} \
    --no-browser \
    --NotebookApp.token='' \
    --NotebookApp.password='' \
    --notebook-dir=/workspace
" &

echo "[startup] all services launched"
echo "[startup]   noVNC     -> http://localhost:${NOVNC_PORT}/vnc.html"
echo "[startup]   VS Code   -> http://localhost:${CODE_SERVER_PORT}"
echo "[startup]   Jupyter   -> http://localhost:${JUPYTER_PORT}"

# Keep the container alive until every background process exits
wait
