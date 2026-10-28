ARG BUILD_FROM
FROM ${BUILD_FROM}

ARG TESLA_FLEET_TELEMETRY_COMMIT=bd076fe1494841707528449560c4a19d0d426da4
ARG TESLA_PROD_CA_SHA256=3eb18d4b8fd228c47411c81f87ec15eda4fffc48cbb3557b4ac2d800059a5a4a

RUN apk add --no-cache ca-certificates jq nginx openssl \
    && mkdir -p /etc/nginx/tesla \
    && wget -qO /etc/nginx/tesla/prod_ca.crt \
       "https://raw.githubusercontent.com/teslamotors/fleet-telemetry/${TESLA_FLEET_TELEMETRY_COMMIT}/config/files/prod_ca.crt" \
    && echo "${TESLA_PROD_CA_SHA256}  /etc/nginx/tesla/prod_ca.crt" | sha256sum -c -

COPY rootfs /

RUN chmod 0755 /run.sh

CMD ["/run.sh"]
