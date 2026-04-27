#!/usr/bin/env bash
# Do NOT use set -e here: background service scripts routinely return non-zero
# during start-dev-env (e.g. x11vnc -bg parent exits 1). Use explicit error handling.
set -uo pipefail

export DISPLAY=:1
export VNC_PORT="${VNC_PORT:-5901}"
export NOVNC_PORT="${NOVNC_PORT:-6080}"

install() {
    src="$1"
    dst="$2"
    if [ ! -e "$src" ]; then
        echo "[start-dev-env] skipping $dst; source $src does not exist"
        return
    fi
    if [ ! -d "$(dirname "$dst")" ]; then
        mkdir -p "$(dirname "$dst")"
    fi
    if [ -e "$dst" ]; then
        echo "[start-dev-env] skipping $dst; already exists"
    else
        echo "[start-dev-env] installing $dst from $src"
        cp -a "$src" "$dst"
    fi
}

# Overwrite the fluxbox config files in the user's home with the defaults from /etc/dev-skel if they don't already exist.
install /etc/dev-skel/fluxbox-init /home/dev/.fluxbox/init
install /etc/dev-skel/fluxbox-menu /home/dev/.fluxbox/menu
install /etc/dev-skel/fluxbox-startup /home/dev/.fluxbox/startup
install /etc/dev-skel/fluxbox-lastwallpaper /home/dev/.fluxbox/lastwallpaper
install /etc/dev-skel/fluxbox-overlay /home/dev/.fluxbox/overlay
install /etc/dev-skel/home-Xresources /home/dev/.Xresources
install /etc/dev-skel/home-fehbg /home/dev/.fehbg
install /etc/dev-skel/home-bashrc /home/dev/.bashrc

chown -R dev:dev /home/dev /opt/conda || true

# Pre-create X11 socket dir as root; Xvfb requires it with sticky-bit perms.
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

# ── X virtual display ────────────────────────────────────────────────────────
# Uses the Xorg dummy driver instead of Xvfb so that RandR can resize the
# framebuffer to any arbitrary size (required for noVNC resize=remote).
# The dummy driver pre-allocates a 4K virtual framebuffer; xrandr --fb
# crops the visible area on demand when the browser window is resized.
# -ac  : disable access control so the dev user can connect without xauth
echo "[start-dev-env] starting Xorg (dummy driver)..."
Xorg :1 -config /etc/X11/xorg-dummy.conf -nolisten tcp -ac &

# Wait until the X socket appears (up to 10 s)
for i in $(seq 1 20); do
  [ -S /tmp/.X11-unix/X1 ] && break
  sleep 0.5
done
echo "[start-dev-env] Xorg ready"

# ── Window manager ───────────────────────────────────────────────────────────
# ~/.fluxbox/start-dev-env sets the wallpaper via feh then execs the WM
su - dev -c "DISPLAY=:1 bash -c '
  xrdb -merge \$HOME/.Xresources 2>/dev/null
  exec /usr/bin/startfluxbox   # runs ~/.fluxbox/startup, which execs fluxbox after setting the wallpaper
'" &

# ── VNC server ───────────────────────────────────────────────────────────────
# -noshm : disable MIT-SHM; required in containers (no shared memory access)
# Run as a bash background job (not x11vnc -bg) to avoid su returning exit 1
echo "[start-dev-env] starting x11vnc..."
su - dev -c "x11vnc -display :1 -forever -shared -rfbport ${VNC_PORT} -nopw -noshm -xrandr" &

# Wait until x11vnc is actually listening (up to 15 s)
for i in $(seq 1 30); do
  bash -c "exec 3<>/dev/tcp/127.0.0.1/${VNC_PORT}" 2>/dev/null && break
  sleep 0.5
done
echo "[start-dev-env] x11vnc ready on :${VNC_PORT}"

# ── noVNC / websockify ───────────────────────────────────────────────────────
echo "[start-dev-env] starting websockify on :${NOVNC_PORT} -> 127.0.0.1:${VNC_PORT}"
websockify --web /usr/share/novnc 0.0.0.0:${NOVNC_PORT} 127.0.0.1:${VNC_PORT} &

echo "[start-dev-env] all services launched"
echo "[start-dev-env]   noVNC     -> http://localhost:${NOVNC_PORT}/vnc.html"

# Keep the container alive until every background process exits
wait
