FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG WITH_CA=0
ARG TARGETARCH

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
    tigervnc-standalone-server \
    xdg-utils \
    xfonts-base \
    xfonts-75dpi \
    xfonts-100dpi \
    xfonts-scalable \
    x11-utils \
    x11-xserver-utils \
    xterm \
    novnc \
    vim \
    plocate \
    && locale-gen en_US.UTF-8 \
    && fc-cache -fv \
    && rm -rf /var/lib/apt/lists/*

# Copy pre-generated cyberpunk wallpaper
COPY workspace/resources/wallpaper.png /usr/share/pixmaps/wallpaper.png

# Install VS Code desktop
RUN curl -fksSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg \
    && echo "deb [arch=${TARGETARCH} signed-by=/usr/share/keyrings/microsoft.gpg] \
https://packages.microsoft.com/repos/code stable main" \
    > /etc/apt/sources.list.d/vscode.list \
    && echo 'Acquire::https::packages.microsoft.com::Verify-Peer "false";' \
       > /etc/apt/apt.conf.d/99microsoft-ssl-bypass \
    && apt-get update && apt-get install -y --no-install-recommends \
    code \
    && rm -f /etc/apt/apt.conf.d/99microsoft-ssl-bypass \
    && rm -rf /var/lib/apt/lists/*

# Install Firefox from Mozilla's apt repo (native deb, no snap, works on amd64 and arm64)
RUN curl -fksSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/mozilla.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/mozilla.gpg] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list \
    && printf "Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n" \
        > /etc/apt/preferences.d/mozilla \
    && apt-get update && apt-get install -y --no-install-recommends firefox \
    && rm -rf /var/lib/apt/lists/*

# Install micromamba (Conda-compatible) and configure conda-forge
# ssl_verify: false is set in .condarc during install to bypass corporate SSL
# inspection, then replaced with the secure default afterwards.
RUN MAMBA_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "linux-aarch64" || echo "linux-64") \
    && curl -kLs https://micro.mamba.pm/api/micromamba/${MAMBA_ARCH}/latest \
    | tar -xvj -C /usr/local/bin --strip-components=1 bin/micromamba \
    && mkdir -p /etc/conda /opt/conda \
    && printf "channels:\n  - conda-forge\nchannel_priority: strict\nssl_verify: false\n" > /etc/conda/.condarc \
    && micromamba install -y -n base -c conda-forge python=3.12 pip jupyterlab notebook \
    && micromamba clean --all --yes \
    && printf "channels:\n  - conda-forge\nchannel_priority: strict\n" > /etc/conda/.condarc

# Make conda available in login shells; symlink conda -> micromamba for tools that expect the conda binary
RUN printf "export MAMBA_ROOT_PREFIX=/opt/conda\nexport PATH=/opt/conda/bin:$PATH\n" > /etc/profile.d/mamba.sh \
    && ln -s /usr/local/bin/micromamba /usr/local/bin/conda

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
COPY bin/update-desktop /usr/local/bin/update-desktop
RUN chmod +x /usr/local/bin/start-dev-env.sh /usr/local/bin/update-desktop

EXPOSE 6080 5901

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/start-dev-env.sh"]
