ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.21
FROM ${BUILD_FROM}

ARG TESLA_FLEET_TELEMETRY_COMMIT=bd076fe1494841707528449560c4a19d0d426da4
ARG TESLA_PROD_CA_SHA256=c572d41d96b106fb20519e7fca3ab70693772aa96d6bab564073bacb097e3282

RUN apk add --no-cache ca-certificates jq nginx openssl \
    && mkdir -p /etc/nginx/tesla \
    && wget -qO /etc/nginx/tesla/prod_ca.crt \
       "https://raw.githubusercontent.com/teslamotors/fleet-telemetry/${TESLA_FLEET_TELEMETRY_COMMIT}/config/files/prod_ca.crt" \
    && echo "${TESLA_PROD_CA_SHA256}  /etc/nginx/tesla/prod_ca.crt" | sha256sum -c -

COPY rootfs /

RUN chmod 0755 /run.sh

CMD ["/run.sh"]
