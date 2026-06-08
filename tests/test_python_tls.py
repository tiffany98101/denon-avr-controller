import base64
import datetime as dt
import hashlib
import importlib
import socket
import ssl
import sys
import threading
import types
from pathlib import Path

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

sys.path.insert(0, str(Path(__file__).parent.parent))

import denon_dashboard_alt as dashboard_alt


class _FakeVariant:
    def __init__(self, signature, value):
        self.signature = signature
        self.value = value


class _FakeGLib:
    Variant = _FakeVariant

    @staticmethod
    def idle_add(func, *args, **kwargs):
        return func(*args, **kwargs)


class _OneShotHttpsServer:
    def __init__(self, cert: Path, key: Path, body: str) -> None:
        self._cert = cert
        self._key = key
        self._body = body.encode("utf-8")
        self._ready = threading.Event()
        self._done = threading.Event()
        self._error: Exception | None = None
        self.port = 0
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self):
        self._thread.start()
        if not self._ready.wait(5):
            if isinstance(self._error, PermissionError):
                pytest.skip(f"local TLS server unavailable: {self._error}")
            assert False, "HTTPS server did not start"
        if isinstance(self._error, PermissionError):
            pytest.skip(f"local TLS server unavailable: {self._error}")
        return self

    def __exit__(self, exc_type, exc, tb):
        self._done.wait(5)
        self._thread.join(timeout=5)

    def _serve(self) -> None:
        try:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(self._cert, self._key)
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
                listener.bind(("127.0.0.1", 0))
                listener.listen(1)
                self.port = listener.getsockname()[1]
                self._ready.set()
                raw, _ = listener.accept()
                with raw:
                    with context.wrap_socket(raw, server_side=True) as conn:
                        conn.settimeout(5)
                        request = b""
                        while b"\r\n\r\n" not in request:
                            chunk = conn.recv(4096)
                            if not chunk:
                                break
                            request += chunk
                        response = (
                            b"HTTP/1.1 200 OK\r\n"
                            + f"Content-Length: {len(self._body)}\r\n".encode("ascii")
                            + b"Content-Type: text/xml\r\n\r\n"
                            + self._body
                        )
                        conn.sendall(response)
        except Exception as exc:
            self._error = exc
            self._ready.set()
        finally:
            self._done.set()


@pytest.fixture
def tls_material(tmp_path: Path):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = issuer = x509.Name(
        [
            x509.NameAttribute(NameOID.COMMON_NAME, "localhost"),
        ]
    )
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=1))
        .not_valid_after(dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=1))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost")]), critical=False)
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )
    cert_path = tmp_path / "receiver.crt"
    key_path = tmp_path / "receiver.key"
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption(),
        )
    )
    spki = cert.public_key().public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    pin = "sha256//" + base64.b64encode(hashlib.sha256(spki).digest()).decode("ascii")
    return cert_path, key_path, pin


def _dashboard_get_config(monkeypatch, port: int) -> str:
    monkeypatch.setattr(dashboard_alt.DirectDashboardProvider, "GET_CONFIG_PORT", port)
    provider = dashboard_alt.DirectDashboardProvider(timeout=5)
    return provider._get_config("localhost", 3)


def test_dashboard_default_insecure_tls_still_connects(monkeypatch, tls_material):
    cert, key, _ = tls_material
    monkeypatch.delenv("DENON_CURL_INSECURE", raising=False)
    monkeypatch.delenv("DENON_CURL_CACERT", raising=False)
    monkeypatch.delenv("DENON_CURL_PINNEDPUBKEY", raising=False)
    with _OneShotHttpsServer(cert, key, "<ok/>") as server:
        assert _dashboard_get_config(monkeypatch, server.port) == "<ok/>"


def test_dashboard_tls_custom_ca_succeeds(monkeypatch, tls_material):
    cert, key, _ = tls_material
    monkeypatch.delenv("DENON_CURL_INSECURE", raising=False)
    monkeypatch.setenv("DENON_CURL_CACERT", str(cert))
    monkeypatch.delenv("DENON_CURL_PINNEDPUBKEY", raising=False)
    with _OneShotHttpsServer(cert, key, "<ok/>") as server:
        assert _dashboard_get_config(monkeypatch, server.port) == "<ok/>"


def test_dashboard_tls_correct_pin_succeeds(monkeypatch, tls_material):
    cert, key, pin = tls_material
    monkeypatch.delenv("DENON_CURL_INSECURE", raising=False)
    monkeypatch.delenv("DENON_CURL_CACERT", raising=False)
    monkeypatch.setenv("DENON_CURL_PINNEDPUBKEY", pin)
    with _OneShotHttpsServer(cert, key, "<ok/>") as server:
        assert _dashboard_get_config(monkeypatch, server.port) == "<ok/>"


def test_dashboard_tls_wrong_pin_fails(monkeypatch, tls_material):
    cert, key, _ = tls_material
    monkeypatch.delenv("DENON_CURL_INSECURE", raising=False)
    monkeypatch.delenv("DENON_CURL_CACERT", raising=False)
    monkeypatch.setenv("DENON_CURL_PINNEDPUBKEY", "sha256//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
    with _OneShotHttpsServer(cert, key, "<ok/>") as server:
        with pytest.raises(RuntimeError, match="pinned public key mismatch"):
            _dashboard_get_config(monkeypatch, server.port)


def _load_mpris(monkeypatch):
    monkeypatch.setitem(sys.modules, "pydbus", types.SimpleNamespace(SessionBus=lambda: None))
    monkeypatch.setitem(sys.modules, "pydbus.generic", types.SimpleNamespace(signal=lambda: object()))
    monkeypatch.setitem(sys.modules, "gi", types.SimpleNamespace())
    monkeypatch.setitem(sys.modules, "gi.repository", types.SimpleNamespace(GLib=_FakeGLib))
    sys.modules.pop("denon_mpris", None)
    return importlib.import_module("denon_mpris")


def test_mpris_tls_correct_pin_succeeds(monkeypatch, tls_material):
    cert, key, pin = tls_material
    monkeypatch.delenv("DENON_CURL_INSECURE", raising=False)
    monkeypatch.delenv("DENON_CURL_CACERT", raising=False)
    monkeypatch.setenv("DENON_CURL_PINNEDPUBKEY", pin)
    mpris = _load_mpris(monkeypatch)
    monkeypatch.setattr(mpris, "AVR_PORT", 0)
    with _OneShotHttpsServer(cert, key, "<ok/>") as server:
        monkeypatch.setattr(mpris, "AVR_PORT", server.port)
        assert mpris._avr_get("localhost", 3, timeout=5) == "<ok/>"
