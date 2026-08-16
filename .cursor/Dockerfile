# Cloud Agent OS must be modern (Cursor's exec-daemon needs a current curl).
# Quartus itself still comes from the lab/MiSTer image:
#   ghcr.io/raetro/quartus:mister  (Prime Lite 17.0.2)
# Do not copy the repository into this image; Cursor checks out source separately.
FROM ghcr.io/raetro/quartus:mister AS quartus
RUN mkdir -p /export-libs \
 && (cp -a /usr/lib/x86_64-linux-gnu/libpng12.so* /export-libs/ \
     || cp -a /usr/lib/libpng12.so* /export-libs/)

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    QUARTUS_PATH=/opt/intelFPGA \
    QUARTUS_ROOTDIR=/opt/intelFPGA/quartus \
    SOPC_KIT_NIOS2=/opt/intelFPGA/nios2eds \
    PATH=/opt/intelFPGA/quartus/bin:/opt/intelFPGA/quartus/linux64/gnu:/opt/intelFPGA/quartus/sopc_builder/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      sudo \
      python3 \
      make \
      g++ \
      libtcmalloc-minimal4 \
      libsm6 \
      libxext6 \
      libxrender1 \
      libxft2 \
      libglib2.0-0 \
      libfontconfig1 \
      libncurses6 \
      locales \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
 && locale-gen en_US.UTF-8

COPY --from=quartus /opt/intelFPGA /opt/intelFPGA
COPY --from=quartus /export-libs/ /usr/lib/x86_64-linux-gnu/

WORKDIR /workspace
RUN mkdir -p /workspace \
 && if ! id ubuntu >/dev/null 2>&1; then \
      useradd --create-home --shell /bin/bash --groups sudo ubuntu; \
    fi \
 && echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu \
 && chmod 0440 /etc/sudoers.d/ubuntu \
 && chown ubuntu:ubuntu /workspace

USER ubuntu
ENTRYPOINT []
CMD ["/bin/bash"]
