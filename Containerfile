ARG BASE_IMAGE=ghcr.io/ublue-os/ucore-minimal
FROM ${BASE_IMAGE}


COPY apply-hostname.service /etc/systemd/system/apply-hostname.service
RUN rpm-ostree install qemu-guest-agent && \
    systemctl enable afterburn-sshkeys@core.service && \
    systemctl enable qemu-guest-agent && \
    systemctl enable apply-hostname.service
