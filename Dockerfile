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
    CODE_SERVER_PORT=13337 \
    NOVNC_PORT=6080 \
    VNC_PORT=5901 \
    JUPYTER_PORT=8888

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
    && locale-gen en_US.UTF-8 \
    && fc-cache -fv \
    && convert -size 1920x1080 gradient:#1a2a4a-#2c5f8a /usr/share/pixmaps/wallpaper.png \
    && rm -rf /var/lib/apt/lists/*

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

# Install VS Code Server (code-server)
RUN curl -fksSL https://code-server.dev/install.sh | sh

# Install Google Chrome
RUN curl -fksSL https://dl.google.com/linux/linux_signing_key.pub \
    | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] \
https://dl.google.com/linux/chrome/deb/ stable main" \
    > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update && apt-get install -y --no-install-recommends \
    google-chrome-stable \
    && rm -rf /var/lib/apt/lists/*

# Install micromamba (Conda-compatible) and configure conda-forge
RUN curl -kLs https://micro.mamba.pm/api/micromamba/linux-64/latest \
    | tar -xvj -C /usr/local/bin --strip-components=1 bin/micromamba \
    && mkdir -p /etc/conda /opt/conda \
    && printf "channels:\n  - conda-forge\nchannel_priority: strict\n" > /etc/conda/.condarc \
    && micromamba install -y -n base -c conda-forge python=3.12 pip jupyterlab notebook \
    && micromamba clean --all --yes

# Make conda available in login shells
RUN printf "export MAMBA_ROOT_PREFIX=/opt/conda\nexport PATH=/opt/conda/bin:$PATH\n" > /etc/profile.d/mamba.sh

# Non-root dev user with sudo, with micromamba pre-initialised in .bashrc
RUN useradd -m -s /bin/bash dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev \
    && printf '\n# micromamba / conda\nexport MAMBA_ROOT_PREFIX=/opt/conda\nexport PATH=/opt/conda/bin:$PATH\neval "$(micromamba shell hook -s bash)"\nmicromamba activate base 2>/dev/null || true\n' >> /home/dev/.bashrc \
    && chown dev:dev /home/dev/.bashrc

# Desktop configuration: fluxbox right-click menu and xterm colour theme
COPY desktop/fluxbox-menu /home/dev/.fluxbox/menu
COPY desktop/Xresources   /home/dev/.Xresources
RUN chown -R dev:dev /home/dev/.fluxbox /home/dev/.Xresources

WORKDIR /workspace
RUN mkdir -p /workspace && chown -R dev:dev /workspace /home/dev /opt/conda

COPY start-dev-env.sh /usr/local/bin/start-dev-env.sh
RUN chmod +x /usr/local/bin/start-dev-env.sh

EXPOSE 6080 5901 13337 8888

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/start-dev-env.sh"]
