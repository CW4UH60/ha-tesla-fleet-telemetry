"""Tests for receiver CA selection without importing Home Assistant."""
from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType

import pytest

_MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "custom_components"
    / "tesla_telemetry"
    / "tls_ca.py"
)


def _load_isolated() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "tesla_telemetry_tls_ca_isolated", _MODULE_PATH
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tls_ca = _load_isolated()

_VALID_CA = (
    tls_ca.DEFAULT_CA_BUNDLE_PEM.split("-----END CERTIFICATE-----", 1)[0]
    + "-----END CERTIFICATE-----\n"
)


def test_service_override_wins(tmp_path: Path) -> None:
    local = tmp_path / "ca.crt"
    local.write_text(_VALID_CA, encoding="ascii")
    pem, source = tls_ca.resolve_ca_bundle(f"\n{_VALID_CA}\n", local)
    assert pem == _VALID_CA
    assert source == "service override"


def test_local_receiver_ca_is_preferred(tmp_path: Path) -> None:
    local = tmp_path / "ca.crt"
    local.write_text(_VALID_CA, encoding="ascii")
    pem, source = tls_ca.resolve_ca_bundle(local_path=local)
    assert pem == _VALID_CA
    assert source == "receiver add-on private CA"


def test_missing_local_ca_falls_back_to_public_bundle(tmp_path: Path) -> None:
    pem, source = tls_ca.resolve_ca_bundle(local_path=tmp_path / "missing.crt")
    assert "-----BEGIN CERTIFICATE-----" in pem
    assert source == "bundled public roots"


@pytest.mark.parametrize(
    "content",
    ["not a certificate", "-----BEGIN CERTIFICATE-----\nmissing end"],
)
def test_invalid_local_ca_fails_closed(tmp_path: Path, content: str) -> None:
    local = tmp_path / "ca.crt"
    local.write_text(content, encoding="ascii")
    with pytest.raises(tls_ca.TelemetryCaError):
        tls_ca.resolve_ca_bundle(local_path=local)
