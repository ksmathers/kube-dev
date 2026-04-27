FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG WITH_CA=0

# Optionally install a corporate CA bundle (copied in by build.sh --with-ca)
COPY CombinedCA.cer* /tmp/
RUN if [ "$WITH_CA" = "1" ] && [ -f /tmp/CombinedCA.cer ]; then \
        apt-get update && apt-get install -y --no-install-recommends ca-certificates \
        && rm -rf /var/lib/apt/lists/* \
        && mkdir -p /usr/local/share/ca-certificates \
        && cp /tmp/CombinedCA.cer /usr/local/share/ca-certificates/CombinedCA.crt \
        && update-ca-certificates; \
    fi

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    MAMBA_ROOT_PREFIX=/opt/conda \
    NOVNC_PORT=6080 \
    VNC_PORT=5901

# Base tools + desktop stack for noVNC
RUN apt-get update && apt-get install -y --no-install-recommends \
    bzip2 \
    ca-certificates \
    curl \
    dbus-x11 \
    feh \
    fluxbox \
    fontconfig \
    fonts-liberation \
    git \
    gnupg \
    imagemagick \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcups2 \
    libdbus-1-3 \
    libgbm1 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libvulkan1 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxkbcommon0 \
    libxrandr2 \
    locales \
    procps \
    python3 \
    python3-pip \
    sudo \
    tini \
    tzdata \
    wget \
    websockify \
    x11vnc \
    xdg-utils \
    xfonts-base \
    xfonts-75dpi \
    xfonts-100dpi \
    xfonts-scalable \
    xterm \
    xvfb \
    novnc \
    vim \
    plocate \
    && locale-gen en_US.UTF-8 \
    && fc-cache -fv \
    && rm -rf /var/lib/apt/lists/*

# Copy pre-generated cyberpunk wallpaper
COPY workspace/resources/wallpaper.png /usr/share/pixmaps/wallpaper.png

# Patch noVNC: add F8 fullscreen toggle and prevent ESC from exiting fullscreen.
# ESC is intercepted by the browser when in fullscreen; we immediately re-enter
# so the key is forwarded to the VNC session (e.g. vim) uninterrupted.
RUN python3 - <<'PYEOF'
import re, pathlib
p = pathlib.Path("/usr/share/novnc/vnc.html")
patch = """
<script>
/* --- custom fullscreen patch --- */
(function () {
  /* F8 toggles fullscreen */
  document.addEventListener("keydown", function (e) {
    if (e.code === "F8") {
      e.preventDefault();
      if (document.fullscreenElement) {
        document.exitFullscreen();
      } else {
        document.documentElement.requestFullscreen();
      }
      return;
    }
    /* ESC while fullscreen: re-enter after browser exits, so VNC still gets Escape */
    if (e.code === "Escape" && document.fullscreenElement) {
      setTimeout(function () {
        if (!document.fullscreenElement) {
          document.documentElement.requestFullscreen();
        }
      }, 80);
    }
  }, true);
}());
/* --- end fullscreen patch --- */
</script>
"""
html = p.read_text()
html = html.replace("</body>", patch + "</body>", 1)
p.write_text(html)
print("noVNC patched OK")
PYEOF

# Install VS Code desktop
RUN curl -fksSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] \
https://packages.microsoft.com/repos/code stable main" \
    > /etc/apt/sources.list.d/vscode.list \
    && echo 'Acquire::https::packages.microsoft.com::Verify-Peer "false";' \
       > /etc/apt/apt.conf.d/99microsoft-ssl-bypass \
    && apt-get update && apt-get install -y --no-install-recommends \
    code \
    && rm -f /etc/apt/apt.conf.d/99microsoft-ssl-bypass \
    && rm -rf /var/lib/apt/lists/*

# Install Google Chrome
# apt needs its own SSL bypass for dl.google.com (it ignores .curlrc).
# We write a per-host apt config that disables TLS verification for that repo
# only, then remove it after the package is installed.
RUN curl -fksSL https://dl.google.com/linux/linux_signing_key.pub \
    | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] \
https://dl.google.com/linux/chrome/deb/ stable main" \
    > /etc/apt/sources.list.d/google-chrome.list \
    && echo 'Acquire::https::dl.google.com::Verify-Peer "false";' \
       > /etc/apt/apt.conf.d/99google-ssl-bypass \
    && apt-get update && apt-get install -y --no-install-recommends \
    google-chrome-stable \
    && rm -f /etc/apt/apt.conf.d/99google-ssl-bypass \
    && rm -rf /var/lib/apt/lists/*

# Install micromamba (Conda-compatible) and configure conda-forge
# ssl_verify: false is set in .condarc during install to bypass corporate SSL
# inspection, then replaced with the secure default afterwards.
RUN curl -kLs https://micro.mamba.pm/api/micromamba/linux-64/latest \
    | tar -xvj -C /usr/local/bin --strip-components=1 bin/micromamba \
    && mkdir -p /etc/conda /opt/conda \
    && printf "channels:\n  - conda-forge\nchannel_priority: strict\nssl_verify: false\n" > /etc/conda/.condarc \
    && micromamba install -y -n base -c conda-forge python=3.12 pip jupyterlab notebook \
    && micromamba clean --all --yes \
    && printf "channels:\n  - conda-forge\nchannel_priority: strict\n" > /etc/conda/.condarc

# Make conda available in login shells
RUN printf "export MAMBA_ROOT_PREFIX=/opt/conda\nexport PATH=/opt/conda/bin:$PATH\n" > /etc/profile.d/mamba.sh

# Non-root dev user with sudo.  We create a home directory for them at /home/dev, but this gets shadowed by the PVC mount at runtime.  
# The start-dev-env.sh script detects this and copies in the default config files from /etc/dev-skel on first run.
RUN useradd -M -s /bin/bash dev \
    && mkdir -p /home/dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev

# Desktop configuration: fluxbox right-click menu and xterm colour theme
# These are copied into /etc/dev-skel so that the PVC can be mounted over /home/dev.  These files get copied into the user's home
# by 'start-dev-env.sh'
COPY desktop/. /etc/dev-skel
RUN chmod +x /etc/dev-skel/fluxbox-startup \
      /etc/dev-skel/home-fehbg \
    && chown -R dev:dev /etc/dev-skel/*

WORKDIR /home/dev
RUN chown -R dev:dev /home/dev /opt/conda

COPY start-dev-env.sh /usr/local/bin/start-dev-env.sh
RUN chmod +x /usr/local/bin/start-dev-env.sh

EXPOSE 6080 5901

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/start-dev-env.sh"]
