# Cloud Agent base: the same Quartus 17.0.2 image the lab farm uses.
# Do not copy the repository into this image; Cursor checks out source separately.
FROM ghcr.io/raetro/quartus:mister

# Reset the image entrypoint so the Cloud Agent launcher is not wrapped.
ENTRYPOINT []
CMD ["/bin/bash"]

# Cursor checks out the selected revision here.
WORKDIR /workspace
RUN mkdir -p /workspace

# The upstream image runs as root. Create the conventional Cloud Agent user.
# Quartus lives in /opt/intelFPGA and is already on PATH via ENV.
RUN if ! id ubuntu >/dev/null 2>&1; then \
      useradd --create-home --shell /bin/bash --groups sudo ubuntu; \
    fi \
 && echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu \
 && chmod 0440 /etc/sudoers.d/ubuntu \
 && chown ubuntu:ubuntu /workspace

USER ubuntu
