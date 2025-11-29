ARG BASE_IMAGE=ubuntu:22.04

FROM ${BASE_IMAGE}

ARG WARP_VERSION
ARG GOST_VERSION
ARG COMMIT_SHA
ARG TARGETPLATFORM

LABEL org.opencontainers.image.title="Cloudflare WARP Docker"
LABEL org.opencontainers.image.description="Docker container for Cloudflare WARP client with GOST proxy support"
LABEL org.opencontainers.image.authors="Ercin Dedeoglu <e.dedeoglu@gmail.com>"
LABEL org.opencontainers.image.url="https://github.com/ErcinDedeoglu/cloudflare-warp-docker"
LABEL org.opencontainers.image.source="https://github.com/ErcinDedeoglu/cloudflare-warp-docker"
LABEL org.opencontainers.image.documentation="https://github.com/ErcinDedeoglu/cloudflare-warp-docker#readme"
LABEL org.opencontainers.image.vendor="Ercin Dedeoglu"
LABEL org.opencontainers.image.licenses="CC-BY-NC-4.0"
LABEL org.opencontainers.image.revision=${COMMIT_SHA}
LABEL org.opencontainers.image.version=${WARP_VERSION}
LABEL WARP_VERSION=${WARP_VERSION}
LABEL GOST_VERSION=${GOST_VERSION}
LABEL COMMIT_SHA=${COMMIT_SHA}

COPY entrypoint.sh /entrypoint.sh
COPY ./healthcheck /healthcheck

# install dependencies
RUN case ${TARGETPLATFORM} in \
      "linux/amd64")   ARCH="amd64" ;; \
      "linux/arm64")   ARCH="arm64" ;; \
      *) echo "Unsupported TARGETPLATFORM: ${TARGETPLATFORM}" && exit 1 ;; \
    esac && \
    echo "Building for ${TARGETPLATFORM} with GOST ${GOST_VERSION} (ARCH=${ARCH})" && \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release sudo jq ipcalc dbus && \
    curl https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends cloudflare-warp && \
    apt-get clean && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/* && \
    # Download GOST from go-gost/gost (v3 - actively maintained)
    FILE_NAME="gost_${GOST_VERSION}_linux_${ARCH}.tar.gz" && \
    echo "Downloading GOST ${GOST_VERSION} (${FILE_NAME})" && \
    curl -fLO "https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/${FILE_NAME}" && \
    tar -xzf ${FILE_NAME} -C /usr/bin/ gost && \
    rm -f ${FILE_NAME} && \
    chmod +x /usr/bin/gost && \
    chmod +x /entrypoint.sh && \
    chmod +x /healthcheck/index.sh && \
    useradd -m -s /bin/bash warp && \
    echo "warp ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/warp

USER warp

# Accept Cloudflare WARP TOS
RUN mkdir -p /home/warp/.local/share/warp && \
    echo -n 'yes' > /home/warp/.local/share/warp/accepted-tos.txt

ENV GOST_ARGS="-L :1080"
ENV WARP_SLEEP=2
ENV REGISTER_WHEN_MDM_EXISTS=
ENV BETA_FIX_HOST_CONNECTIVITY=
ENV WARP_ENABLE_NAT=

# NOTE: WARP_LICENSE_KEY should be provided at runtime via:
#   docker run -e WARP_LICENSE_KEY=your-key ...
# or using Docker secrets to avoid credential leakage in build logs/image metadata

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD /healthcheck/index.sh

ENTRYPOINT ["/entrypoint.sh"]