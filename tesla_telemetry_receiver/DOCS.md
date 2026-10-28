# Tesla Fleet Telemetry Receiver

This add-on terminates the Tesla vehicle's mutual-TLS WebSocket and forwards
only verified streams to the `Tesla Fleet Telemetry` custom integration in
Home Assistant.

## Configuration

- `hostname`: dedicated public DNS name for telemetry. It must be a DNS-only
  record, not a normal Cloudflare Tunnel hostname.
- `proxy_secret`: 32-128 URL-safe characters. Use the same value in each
  integration entry. Do not publish it.
On first start the add-on creates a private CA and a server certificate in
`/ssl/tesla-telemetry`. The integration automatically uses
`/ssl/tesla-telemetry/ca.crt` when it pushes the vehicle telemetry config.
Certificates are reused across restarts. A hostname change or certificate
renewal first creates a timestamped backup under
`/ssl/tesla-telemetry/backups`.

Forward TCP port `4443` from the router to the Home Assistant host,
and point the dedicated DNS-only hostname at the router's public address.
Tesla connects directly with mTLS; an HTTP-only reverse tunnel cannot carry
this protocol.

The Tesla production client CA is downloaded at image build time from the
official `teslamotors/fleet-telemetry` repository at a pinned commit and
verified by SHA-256 before the image is created.
