ARG BASE_IMAGE=ubuntu:24.04

FROM ${BASE_IMAGE}

ARG COMMIT_SHA
ARG TARGETPLATFORM

LABEL org.opencontainers.image.title="Cloudflare WARP"
LABEL org.opencontainers.image.description="Docker container for Cloudflare WARP client with GOST proxy support"
LABEL org.opencontainers.image.authors="Ercin Dedeoglu <e.dedeoglu@gmail.com>"
LABEL org.opencontainers.image.url="https://github.com/ErcinDedeoglu/cloudflare-warp"
LABEL org.opencontainers.image.source="https://github.com/ErcinDedeoglu/cloudflare-warp"
LABEL org.opencontainers.image.documentation="https://github.com/ErcinDedeoglu/cloudflare-warp#readme"
LABEL org.opencontainers.image.vendor="Ercin Dedeoglu"
LABEL org.opencontainers.image.licenses="CC-BY-NC-4.0"
LABEL org.opencontainers.image.revision=${COMMIT_SHA}
LABEL COMMIT_SHA=${COMMIT_SHA}

COPY entrypoint.sh /entrypoint.sh
COPY start-warp-instance.sh /start-warp-instance.sh
COPY ./healthcheck /healthcheck

RUN case ${TARGETPLATFORM} in \
      "linux/amd64")   ARCH="amd64" ;; \
      "linux/arm64")   ARCH="arm64" ;; \
      *) echo "Unsupported TARGETPLATFORM: ${TARGETPLATFORM}" && exit 1 ;; \
    esac && \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release sudo jq dbus && \
    curl https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends cloudflare-warp && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    GOST_VERSION=$(curl -s https://api.github.com/repos/go-gost/gost/releases/latest | jq -r '.tag_name' | sed 's/^v//') && \
    echo "Installing GOST version: ${GOST_VERSION}" && \
    FILE_NAME="gost_${GOST_VERSION}_linux_${ARCH}.tar.gz" && \
    curl -fLO "https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/${FILE_NAME}" && \
    tar -xzf ${FILE_NAME} -C /usr/bin/ gost && \
    rm -f ${FILE_NAME} && \
    chmod +x /usr/bin/gost && \
    chmod +x /entrypoint.sh && \
    chmod +x /start-warp-instance.sh && \
    chmod +x /healthcheck/index.sh && \
    useradd -m -s /bin/bash warp && \
    echo "warp ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/warp

USER warp

RUN mkdir -p /home/warp/.local/share/warp && \
    echo -n 'yes' > /home/warp/.local/share/warp/accepted-tos.txt

ENV WARP_INSTANCES=1
ENV WARP_CONNECT_TIMEOUT=30
ENV PROXY_USER=
ENV PROXY_PASS=
ENV PROXY_MAX_CONN=10
ENV PROXY_MAX_RPS=10
ENV PROXY_ALLOWED_IPS=
ENV SS_METHOD=chacha20-ietf-poly1305

HEALTHCHECK --interval=15s --timeout=5s --start-period=120s --retries=3 \
  CMD /healthcheck/index.sh

ENTRYPOINT ["/entrypoint.sh"]
