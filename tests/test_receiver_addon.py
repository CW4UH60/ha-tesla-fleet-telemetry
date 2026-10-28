"""Static security invariants for the companion receiver add-on."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "tesla_telemetry_receiver"


def test_tesla_client_ca_is_pinned_and_verified() -> None:
    dockerfile = (ADDON / "Dockerfile").read_text(encoding="utf-8")
    assert "TESLA_FLEET_TELEMETRY_COMMIT=" in dockerfile
    assert "TESLA_PROD_CA_SHA256=" in dockerfile
    assert "sha256sum -c" in dockerfile
    assert ":latest" not in dockerfile


def test_proxy_requires_vehicle_mtls_and_overwrites_identity_headers() -> None:
    nginx = (
        ADDON
        / "rootfs"
        / "etc"
        / "nginx"
        / "templates"
        / "tesla-telemetry.conf.template"
    ).read_text(encoding="utf-8")
    assert "ssl_verify_client on;" in nginx
    assert "ssl_client_certificate /etc/nginx/tesla/prod_ca.crt;" in nginx
    assert "proxy_set_header X-Tesla-Proxy-Secret" in nginx
    assert "proxy_set_header X-Tesla-Verified-Vin $ssl_client_s_dn;" in nginx
    assert "access_log off;" in nginx


def test_private_keys_are_not_part_of_the_repository() -> None:
    tracked_names = {path.name for path in ADDON.rglob("*") if path.is_file()}
    assert "ca.key" not in tracked_names
    assert "server.key" not in tracked_names
