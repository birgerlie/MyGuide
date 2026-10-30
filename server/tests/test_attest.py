import base64
import hashlib
import threading
from datetime import timedelta

import cbor2
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from myguide.attest import AttestError, Challenges, apple_root, verify_attestation
from tests.attest_fixtures import NOW, PROD_AAGUID, key_id_of, make_attestation

APP_ID = "TEAMID.io.github.birgerlie.MyGuide"
CHALLENGE = b"c" * 32


def verify(attestation, key_id, root, *, challenge=CHALLENGE, app_id=APP_ID, allow_development=True, now=NOW):
    verify_attestation(
        attestation=attestation, key_id_b64=key_id, challenge=challenge, app_id=app_id,
        allow_development=allow_development, root=root, now=now,
    )


def reason(exc_info) -> str:
    assert exc_info.value.args[0] == exc_info.value.reason
    return exc_info.value.reason


def reencode(attestation: bytes, mutate) -> bytes:
    obj = cbor2.loads(attestation)
    mutate(obj)
    return cbor2.dumps(obj)


# --- happy paths -------------------------------------------------------------------------------------------

def test_development_attestation_passes_when_allowed():
    att, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE)
    verify(att, kid, root, allow_development=True)


def test_development_attestation_refused_when_not_allowed():
    att, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE)
    with pytest.raises(AttestError) as e:
        verify(att, kid, root, allow_development=False)
    assert reason(e) == "aaguid"


def test_production_attestation_passes_without_development():
    att, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE, aaguid=PROD_AAGUID)
    verify(att, kid, root, allow_development=False)


def test_production_attestation_passes_with_development_allowed_too():
    att, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE, aaguid=PROD_AAGUID)
    verify(att, kid, root, allow_development=True)


def test_same_root_key_gives_interchangeable_roots():
    key = ec.generate_private_key(ec.SECP384R1())
    att, kid, _ = make_attestation(app_id=APP_ID, challenge=CHALLENGE, root_key=key)
    _, _, root2 = make_attestation(app_id=APP_ID, challenge=CHALLENGE, root_key=key)
    verify(att, kid, root2)


# --- each check ----------------------------------------------------------------------------------------------

def test_wrong_app_id_is_rp_id():
    att, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE)
    with pytest.raises(AttestError) as e:
        verify(att, kid, root, app_id="OTHERTEAM.io.github.birgerlie.MyGuide")
    assert reason(e) == "rp_id"


def test_nonce_override_is_nonce():
    att, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE, nonce_override=b"\x01" * 32)
    with pytest.raises(AttestError) as e:
        verify(att, kid, root)
    assert reason(e) == "nonce"


def test_other_challenge_is_nonce():
    att, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE)
    with pytest.raises(AttestError) as e:
        verify(att, kid, root, challenge=b"d" * 32)
    assert reason(e) == "nonce"


def test_counter_one_is_counter():
    att, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE, counter=1)
    with pytest.raises(AttestError) as e:
        verify(att, kid, root)
    assert reason(e) == "counter"


def test_unknown_aaguid_is_aaguid_even_with_development():
    att, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE, aaguid=b"appattestXXXXXXX")
    with pytest.raises(AttestError) as e:
        verify(att, kid, root, allow_development=True)
    assert reason(e) == "aaguid"


def test_chain_on_another_root_is_chain():
    att, kid, _ = make_attestation(app_id=APP_ID, challenge=CHALLENGE)
    _, _, other_root = make_attestation(app_id=APP_ID, challenge=CHALLENGE)
    with pytest.raises(AttestError) as e:
        verify(att, kid, other_root)
    assert reason(e) == "chain"


def test_test_chain_against_apple_root_is_chain():
    att, kid, _ = make_attestation(app_id=APP_ID, challenge=CHALLENGE)
    with pytest.raises(AttestError) as e:
        verify(att, kid, apple_root())
    assert reason(e) == "chain"


def test_leaf_not_signed_by_intermediate_is_chain():
    # Leaf from attestation A, intermediate from attestation B, both under the same root.
    key = ec.generate_private_key(ec.SECP384R1())
    att_a, kid_a, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE, root_key=key)
    att_b, _, _ = make_attestation(app_id=APP_ID, challenge=CHALLENGE, root_key=key)
    intermediate_b = cbor2.loads(att_b)["attStmt"]["x5c"][1]
    swapped = reencode(att_a, lambda o: o["attStmt"]["x5c"].__setitem__(1, intermediate_b))
    with pytest.raises(AttestError) as e:
        verify(swapped, kid_a, root)
    assert reason(e) == "chain"


def test_leaf_expired_is_chain():
    att, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE)
    with pytest.raises(AttestError) as e:
        verify(att, kid, root, now=NOW + timedelta(days=2))  # leaf ends NOW+1d, CAs NOW+3650d
    assert reason(e) == "chain"


def test_leaf_not_yet_valid_is_chain():
    att, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE)
    with pytest.raises(AttestError) as e:
        verify(att, kid, root, now=NOW - timedelta(hours=2))  # leaf starts NOW-1h
    assert reason(e) == "chain"


def test_leaf_valid_at_its_last_instant():
    att, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE)
    leaf_end = NOW + timedelta(days=1)
    verify(att, kid, root, now=leaf_end)
    with pytest.raises(AttestError):
        verify(att, kid, root, now=leaf_end + timedelta(seconds=1))


def test_root_expired_is_chain():
    att, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE)
    with pytest.raises(AttestError) as e:
        verify(att, kid, root, now=NOW + timedelta(days=3651))
    assert reason(e) == "chain"


def test_key_id_of_another_key_is_key_id():
    att, _, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE)
    other = key_id_of(ec.generate_private_key(ec.SECP256R1()).public_key())
    with pytest.raises(AttestError) as e:
        verify(att, other, root)
    assert reason(e) == "key_id"


def test_key_id_matching_credential_id_but_not_leaf_key_is_key_id():
    # authData's credential id and the presented key id agree, but the leaf certificate holds a different key:
    # only the SHA256(leaf public key) check can catch this.
    forged = b"\x07" * 32
    att, _, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE, credential_id_override=forged)
    with pytest.raises(AttestError) as e:
        verify(att, base64.b64encode(forged).decode(), root)
    assert reason(e) == "key_id"


def test_key_id_not_base64_is_key_id():
    att, _, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE)
    with pytest.raises(AttestError) as e:
        verify(att, "not base64 !!", root)
    assert reason(e) == "key_id"


def test_credential_id_differs_from_key_id_is_key_id():
    # authData carries another credential id, and the nonce is computed over that authData, so every earlier
    # check passes and only the credential-id comparison fails.
    att, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE, credential_id_override=b"\x07" * 32)
    with pytest.raises(AttestError) as e:
        verify(att, kid, root)
    assert reason(e) == "key_id"


def test_tampered_authdata_is_nonce():
    att, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE)
    def flip(o):
        auth = bytearray(o["authData"])
        auth[55] ^= 0xFF
        o["authData"] = bytes(auth)
    with pytest.raises(AttestError) as e:
        verify(reencode(att, flip), kid, root)
    assert reason(e) == "nonce"


def test_naive_now_is_a_caller_error():
    att, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE)
    with pytest.raises(ValueError):
        verify(att, kid, root, now=NOW.replace(tzinfo=None))


# --- format --------------------------------------------------------------------------------------------------

def test_other_fmt_is_format():
    att, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE)
    bad = reencode(att, lambda o: o.__setitem__("fmt", "packed"))
    with pytest.raises(AttestError) as e:
        verify(bad, kid, root)
    assert reason(e) == "format"


@pytest.mark.parametrize("garbage", [b"", b"\xff\xff\xff", b"not cbor at all", cbor2.dumps([1, 2, 3]),
                                     cbor2.dumps({"fmt": "apple-appattest"})])
def test_garbage_is_format(garbage):
    _, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE)
    with pytest.raises(AttestError) as e:
        verify(garbage, kid, root)
    assert reason(e) == "format"


@pytest.mark.parametrize("mutate", [
    lambda o: o["attStmt"].__setitem__("x5c", o["attStmt"]["x5c"][:1]),
    lambda o: o["attStmt"].__setitem__("x5c", "nope"),
    lambda o: o["attStmt"]["x5c"].__setitem__(0, b"not a certificate"),
    lambda o: o.__setitem__("authData", o["authData"][:54]),
    lambda o: o.__setitem__("authData", o["authData"][:60]),  # credential id length says 32, only 5 present
    lambda o: o.__setitem__("authData", "text"),
    lambda o: o.__delitem__("attStmt"),
])
def test_malformed_fields_are_format(mutate):
    att, kid, root = make_attestation(app_id=APP_ID, challenge=CHALLENGE)
    with pytest.raises(AttestError) as e:
        verify(reencode(att, mutate), kid, root)
    assert reason(e) == "format"


# --- Apple root ----------------------------------------------------------------------------------------------

def test_apple_root_loads():
    root = apple_root()
    assert "Apple App Attestation Root CA" in root.subject.rfc4514_string()
    assert isinstance(root.public_key(), ec.EllipticCurvePublicKey)


def test_apple_root_fingerprint_matches_recorded_value():
    der = apple_root().public_bytes(serialization.Encoding.DER)
    assert hashlib.sha256(der).hexdigest().upper() == (
        "1CB9823BA28BA6AD2D33A006941DE2AE4F513EF1D4E831B9F7E0FA7B6242C932"
    )


# --- Challenges ----------------------------------------------------------------------------------------------

def test_challenge_is_32_random_bytes_in_standard_base64():
    ch = Challenges(lambda: 300)
    a, b = ch.issue(1000.0), ch.issue(1000.0)
    assert len(base64.b64decode(a, validate=True)) == 32
    assert a != b


def test_challenge_consumed_once():
    ch = Challenges(lambda: 300)
    c = ch.issue(1000.0)
    assert ch.consume(c, 1001.0) == base64.b64decode(c)
    assert ch.consume(c, 1002.0) is None


def test_challenge_valid_at_ttl_expired_after():
    ch = Challenges(lambda: 300)
    c1, c2 = ch.issue(1000.0), ch.issue(1000.0)
    assert ch.consume(c1, 1300.0) is not None  # exactly ttl: still valid
    assert ch.consume(c2, 1301.0) is None  # ttl + 1 s: expired


def test_challenge_ttl_read_at_use_time():
    ttl = [300]
    ch = Challenges(lambda: ttl[0])
    c = ch.issue(1000.0)
    ttl[0] = 10
    assert ch.consume(c, 1011.0) is None


def test_unknown_challenge_is_none():
    ch = Challenges(lambda: 300)
    ch.issue(1000.0)
    assert ch.consume(base64.b64encode(b"x" * 32).decode(), 1001.0) is None
    assert ch.consume("not base64 !!", 1001.0) is None
    assert ch.consume("", 1001.0) is None


def test_expired_challenges_are_purged():
    ch = Challenges(lambda: 300)
    for _ in range(5):
        ch.issue(1000.0)
    ch.issue(2000.0)
    assert len(ch) == 1


def test_concurrent_consume_succeeds_once():
    ch = Challenges(lambda: 300)
    c = ch.issue(1000.0)
    results = []
    barrier = threading.Barrier(8)

    def worker():
        barrier.wait()
        results.append(ch.consume(c, 1001.0))

    threads = [threading.Thread(target=worker) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sum(r is not None for r in results) == 1
