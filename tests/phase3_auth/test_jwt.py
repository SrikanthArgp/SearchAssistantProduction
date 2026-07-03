from datetime import datetime, timedelta, timezone

import pytest
from jose import JWTError, jwt as jose_jwt

from auth.jwt import ALGORITHM, create_access_token, create_refresh_token, decode_token


def test_access_token_round_trip_has_expected_claims():
    token = create_access_token("user-123", "a@b.com", "alice")
    claims = decode_token(token)

    assert claims["sub"] == "user-123"
    assert claims["email"] == "a@b.com"
    assert claims["username"] == "alice"
    assert claims["type"] == "access"
    assert claims["exp"] > claims["iat"]


def test_refresh_token_round_trip_has_expected_claims():
    token = create_refresh_token("user-123")
    claims = decode_token(token)

    assert claims["sub"] == "user-123"
    assert claims["type"] == "refresh"
    assert "email" not in claims
    assert claims["exp"] - claims["iat"] == pytest.approx(7 * 24 * 3600, abs=5)


def test_tampered_token_is_rejected():
    token = create_access_token("user-123", "a@b.com", "alice")
    header, payload, signature = token.split(".")

    # Flip a character in the middle of the payload, not the last character of any
    # base64url segment. The last character of a base64url segment can carry unused
    # padding bits (256-bit signatures encode to 43 chars, where the last char only
    # holds 4 real bits) — flipping it sometimes leaves the decoded bytes unchanged,
    # making this assertion flaky. A middle character always encodes a full 6 bits.
    mid = len(payload) // 2
    tampered_char = "A" if payload[mid] != "A" else "B"
    tampered_payload = payload[:mid] + tampered_char + payload[mid + 1 :]
    tampered = f"{header}.{tampered_payload}.{signature}"

    with pytest.raises(JWTError):
        decode_token(tampered)


def test_expired_token_is_rejected():
    now = datetime.now(timezone.utc)
    expired_claims = {
        "sub": "user-123",
        "jti": "some-jti",
        "type": "access",
        "iat": now - timedelta(minutes=30),
        "exp": now - timedelta(minutes=15),
    }
    import os

    expired_token = jose_jwt.encode(expired_claims, os.environ["JWT_SECRET_KEY"], algorithm=ALGORITHM)

    with pytest.raises(JWTError):
        decode_token(expired_token)


def test_token_signed_with_wrong_secret_is_rejected():
    now = datetime.now(timezone.utc)
    claims = {
        "sub": "user-123",
        "type": "access",
        "iat": now,
        "exp": now + timedelta(minutes=15),
    }
    forged = jose_jwt.encode(claims, "not-the-real-secret", algorithm=ALGORITHM)

    with pytest.raises(JWTError):
        decode_token(forged)
