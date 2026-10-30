"""App Attest: proves a call comes from the real MyGuide app before a token is issued (spec 5).

Follows Apple's "Validating apps that connect to your server" (attestation object, steps 1-9; step 9, the receipt,
is not checked).

Trust anchor: `apple_app_attest_root.pem`, next to this module.
  Subject:  CN=Apple App Attestation Root CA, O=Apple Inc., ST=California (valid 2020-03-18 .. 2045-03-15)
  SHA-256:  1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32
  Source:   https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem, fetched over HTTPS
            2026-10-31; Apple's developer documentation links it via https://www.apple.com/certificateauthority/private.
            Apple publishes no fingerprint for this root (neither /certificateauthority/ nor /private lists one).
  Cross-check (2026-10-31): byte-identical (DER) to the root embedded in veehaitch/devicecheck-appattest,
            src/main/kotlin/ch/veehait/devicecheck/appattest/attestation/AttestationValidator.kt at commit
            cb26211f63c1e2e7949deafe2efdf352daca27fa (raw.githubusercontent.com over HTTPS). Same fingerprint.

Nothing here logs attestation bytes, key ids or challenges.
"""
from __future__ import annotations

import base64
import binascii
import functools
import hashlib
import hmac
import secrets
import threading
from collections.abc import Callable
from datetime import datetime
from importlib import resources

import cbor2
from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ObjectIdentifier

NONCE_OID = ObjectIdentifier("1.2.840.113635.100.8.2")
_NONCE_PREFIX = bytes([0x30, 0x24, 0xA1, 0x22, 0x04, 0x20])  # SEQUENCE { [1] { OCTET STRING (32) } }
PRODUCTION_AAGUID = b"appattest" + b"\x00" * 7
DEVELOPMENT_AAGUID = b"appattestdevelop"
_AUTH_DATA_FIXED = 55  # rpIdHash 32 | flags 1 | counter 4 | aaguid 16 | credentialIdLength 2


class AttestError(Exception):
    """Attestation refused. `reason` (also `args[0]`) is one of: format, chain, nonce, key_id, rp_id, counter,
    aaguid."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


@functools.cache
def apple_root() -> x509.Certificate:
    pem = resources.files(__package__).joinpath("apple_app_attest_root.pem").read_bytes()
    return x509.load_pem_x509_certificate(pem)


def _parse(attestation: bytes) -> tuple[x509.Certificate, x509.Certificate, bytes]:
    try:
        obj = cbor2.loads(attestation)
    except Exception:  # cbor2 raises several types on hostile input; all mean "not an attestation"
        raise AttestError("format") from None
    if not isinstance(obj, dict) or obj.get("fmt") != "apple-appattest":
        raise AttestError("format")
    stmt, auth_data = obj.get("attStmt"), obj.get("authData")
    if not isinstance(stmt, dict) or not isinstance(auth_data, bytes):
        raise AttestError("format")
    x5c = stmt.get("x5c")
    if not isinstance(x5c, list) or len(x5c) != 2 or not all(isinstance(c, bytes) for c in x5c):
        raise AttestError("format")
    try:
        leaf, intermediate = (x509.load_der_x509_certificate(c) for c in x5c)
    except ValueError:
        raise AttestError("format") from None
    if len(auth_data) < _AUTH_DATA_FIXED:
        raise AttestError("format")
    id_len = int.from_bytes(auth_data[53:55], "big")
    if len(auth_data) < _AUTH_DATA_FIXED + id_len:
        raise AttestError("format")
    return leaf, intermediate, auth_data


def _check_chain(leaf: x509.Certificate, intermediate: x509.Certificate, root: x509.Certificate,
                 now: datetime) -> None:
    for cert in (leaf, intermediate, root):
        if not (cert.not_valid_before_utc <= now <= cert.not_valid_after_utc):
            raise AttestError("chain")
    for cert, issuer in ((leaf, intermediate), (intermediate, root)):
        try:
            if not isinstance(issuer.public_key(), ec.EllipticCurvePublicKey):
                raise AttestError("chain")
            # Checks issuer name == cert's issuer, then the ECDSA signature with cert.signature_hash_algorithm.
            cert.verify_directly_issued_by(issuer)
        except AttestError:
            raise
        except Exception:  # InvalidSignature, ValueError (name mismatch, bad key), TypeError, UnsupportedAlgorithm
            raise AttestError("chain") from None


def _leaf_nonce(leaf: x509.Certificate) -> bytes:
    try:
        ext = leaf.extensions.get_extension_for_oid(NONCE_OID).value
    except (x509.ExtensionNotFound, ValueError):
        raise AttestError("nonce") from None
    value = getattr(ext, "value", None)
    if not isinstance(value, bytes) or len(value) != len(_NONCE_PREFIX) + 32 or not value.startswith(_NONCE_PREFIX):
        raise AttestError("nonce")
    return value[len(_NONCE_PREFIX):]


def verify_attestation(*, attestation: bytes, key_id_b64: str, challenge: bytes, app_id: str,
                       allow_development: bool, root: x509.Certificate, now: datetime) -> None:
    """Raises AttestError(reason) or returns. Order: format, chain, nonce, key_id, rp_id, counter, aaguid,
    credential id (reason key_id). `now` must be timezone-aware (ValueError otherwise: a caller bug, not a
    refusal)."""
    if now.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    leaf, intermediate, auth_data = _parse(attestation)
    _check_chain(leaf, intermediate, root, now)

    client_data_hash = hashlib.sha256(challenge).digest()
    expected_nonce = hashlib.sha256(auth_data + client_data_hash).digest()
    if not hmac.compare_digest(_leaf_nonce(leaf), expected_nonce):
        raise AttestError("nonce")

    try:
        key_id = base64.b64decode(key_id_b64, validate=True)
    except (binascii.Error, ValueError):
        raise AttestError("key_id") from None
    try:
        leaf_key = leaf.public_key()
    except Exception:  # unsupported key type; the chain check already parsed it, so this is defensive
        raise AttestError("key_id") from None
    if not isinstance(leaf_key, ec.EllipticCurvePublicKey):
        raise AttestError("key_id")
    point = leaf_key.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    if not hmac.compare_digest(hashlib.sha256(point).digest(), key_id):
        raise AttestError("key_id")

    if not hmac.compare_digest(auth_data[0:32], hashlib.sha256(app_id.encode()).digest()):
        raise AttestError("rp_id")
    if int.from_bytes(auth_data[33:37], "big") != 0:
        raise AttestError("counter")
    aaguid = auth_data[37:53]
    if not (aaguid == PRODUCTION_AAGUID or (allow_development and aaguid == DEVELOPMENT_AAGUID)):
        raise AttestError("aaguid")
    id_len = int.from_bytes(auth_data[53:55], "big")
    if not hmac.compare_digest(auth_data[_AUTH_DATA_FIXED:_AUTH_DATA_FIXED + id_len], key_id):
        raise AttestError("key_id")


class Challenges:
    """One-use attestation challenges, in memory (single process). A challenge is valid while
    `now - issued_at <= ttl()`; the ttl is read on every call, so a settings change applies at once."""

    def __init__(self, ttl: Callable[[], int]) -> None:
        self._ttl = ttl
        self._issued: dict[bytes, float] = {}
        self._lock = threading.Lock()

    def __len__(self) -> int:
        with self._lock:
            return len(self._issued)

    def _purge(self, now: float, ttl: int) -> None:
        for key in [k for k, at in self._issued.items() if now - at > ttl]:
            del self._issued[key]

    def issue(self, now: float) -> str:
        raw = secrets.token_bytes(32)
        with self._lock:
            self._purge(now, self._ttl())
            self._issued[raw] = now
        return base64.b64encode(raw).decode()

    def consume(self, challenge_b64: str, now: float) -> bytes | None:
        try:
            raw = base64.b64decode(challenge_b64, validate=True)
        except (binascii.Error, ValueError):
            return None
        with self._lock:
            ttl = self._ttl()
            self._purge(now, ttl)
            issued_at = self._issued.pop(raw, None)
        if issued_at is None or now - issued_at > ttl:
            return None
        return raw
