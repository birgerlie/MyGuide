"""Builds App Attest attestation objects signed by a throwaway test chain.

Chain: root (P-384, self-signed CA) -> intermediate (P-384 CA) -> leaf (P-256) carrying the nonce extension
OID 1.2.840.113635.100.8.2 with DER value `30 24 a1 22 04 20` + 32-byte nonce, the layout Apple uses.

Validity (relative to NOW): root and intermediate NOW-365d .. NOW+3650d; leaf NOW-1h .. NOW+1d, so tests can put
`now` outside the leaf's window while the CAs are still valid.
"""
from __future__ import annotations

import base64
import hashlib
from datetime import datetime, timedelta, timezone

import cbor2
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID, ObjectIdentifier

NOW = datetime(2026, 10, 30, 12, 0, tzinfo=timezone.utc)
NONCE_OID = ObjectIdentifier("1.2.840.113635.100.8.2")
PROD_AAGUID = b"appattest" + b"\x00" * 7
DEV_AAGUID = b"appattestdevelop"


def _name(cn: str) -> x509.Name:
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])


def _cert(*, subject, issuer, public_key, signing_key, algorithm, not_before, not_after, ca, nonce=None):
    builder = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(public_key)
        .serial_number(x509.random_serial_number())
        .not_valid_before(not_before)
        .not_valid_after(not_after)
        .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
    )
    if nonce is not None:
        value = bytes([0x30, 0x24, 0xA1, 0x22, 0x04, 0x20]) + nonce
        builder = builder.add_extension(x509.UnrecognizedExtension(NONCE_OID, value), critical=False)
    return builder.sign(signing_key, algorithm)


def x962(public_key: ec.EllipticCurvePublicKey) -> bytes:
    return public_key.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def key_id_of(public_key: ec.EllipticCurvePublicKey) -> str:
    return base64.b64encode(hashlib.sha256(x962(public_key)).digest()).decode()


def make_attestation(
    *,
    app_id: str,
    challenge: bytes,
    aaguid: bytes = DEV_AAGUID,
    counter: int = 0,
    nonce_override: bytes | None = None,
    root_key: ec.EllipticCurvePrivateKey | None = None,
    credential_id_override: bytes | None = None,
) -> tuple[bytes, str, x509.Certificate]:
    """Returns `(attestation, key_id_b64, root_cert)`. key_id_b64 is always the leaf key's id;
    `credential_id_override` only changes the credential id written into authData."""
    root_key = root_key or ec.generate_private_key(ec.SECP384R1())
    root_name = _name("Test App Attestation Root CA")
    root = _cert(
        subject=root_name, issuer=root_name, public_key=root_key.public_key(), signing_key=root_key,
        algorithm=hashes.SHA384(), not_before=NOW - timedelta(days=365), not_after=NOW + timedelta(days=3650),
        ca=True,
    )
    int_key = ec.generate_private_key(ec.SECP384R1())
    int_name = _name("Test App Attestation CA 1")
    intermediate = _cert(
        subject=int_name, issuer=root_name, public_key=int_key.public_key(), signing_key=root_key,
        algorithm=hashes.SHA384(), not_before=NOW - timedelta(days=365), not_after=NOW + timedelta(days=3650),
        ca=True,
    )

    leaf_key = ec.generate_private_key(ec.SECP256R1())
    key_id = hashlib.sha256(x962(leaf_key.public_key())).digest()
    credential_id = credential_id_override if credential_id_override is not None else key_id
    auth_data = (
        hashlib.sha256(app_id.encode()).digest()
        + bytes([0x40])
        + counter.to_bytes(4, "big")
        + aaguid
        + len(credential_id).to_bytes(2, "big")
        + credential_id
        + b"\xa5cose-public-key-not-parsed"
    )
    nonce = nonce_override or hashlib.sha256(auth_data + hashlib.sha256(challenge).digest()).digest()
    leaf = _cert(
        subject=_name("leaf"), issuer=int_name, public_key=leaf_key.public_key(), signing_key=int_key,
        algorithm=hashes.SHA256(), not_before=NOW - timedelta(hours=1), not_after=NOW + timedelta(days=1),
        ca=False, nonce=nonce,
    )

    attestation = cbor2.dumps({
        "fmt": "apple-appattest",
        "attStmt": {
            "x5c": [leaf.public_bytes(serialization.Encoding.DER),
                    intermediate.public_bytes(serialization.Encoding.DER)],
            "receipt": b"test-receipt",
        },
        "authData": auth_data,
    })
    return attestation, base64.b64encode(key_id).decode(), root
