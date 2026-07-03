import uuid

import pytest
from fakeredis import aioredis as fakeredis_aioredis
from fastapi import HTTPException
from fastapi.security import HTTPAuthorizationCredentials
from redis.exceptions import ConnectionError as RedisConnectionError

from auth.dependencies import get_current_user
from auth.jwt import create_access_token, create_refresh_token
from db.models import User


class _UnavailableRedis:
    """Simulates a Redis outage: any call raises a connection error."""

    async def exists(self, *args, **kwargs):
        raise RedisConnectionError("connection refused")


class _FakeResult:
    def __init__(self, user):
        self._user = user

    def scalar_one_or_none(self):
        return self._user


class _FakeDBSession:
    def __init__(self, user):
        self._user = user

    async def execute(self, *args, **kwargs):
        return _FakeResult(self._user)


def _credentials(token: str) -> HTTPAuthorizationCredentials:
    return HTTPAuthorizationCredentials(scheme="Bearer", credentials=token)


def _active_user(user_id: uuid.UUID) -> User:
    return User(
        id=user_id,
        email="a@b.com",
        username="alice",
        hashed_password="irrelevant",
        is_active=True,
    )


async def test_valid_access_token_returns_active_user():
    user_id = uuid.uuid4()
    token = create_access_token(str(user_id), "a@b.com", "alice")
    redis_client = fakeredis_aioredis.FakeRedis(decode_responses=True)
    db_session = _FakeDBSession(_active_user(user_id))

    user = await get_current_user(_credentials(token), db_session, redis_client)

    assert user.id == user_id
    assert user.is_active


async def test_revoked_token_is_rejected():
    user_id = uuid.uuid4()
    token = create_access_token(str(user_id), "a@b.com", "alice")
    from auth.jwt import decode_token

    jti = decode_token(token)["jti"]

    redis_client = fakeredis_aioredis.FakeRedis(decode_responses=True)
    await redis_client.set(f"revoked_token:{jti}", "1")
    db_session = _FakeDBSession(_active_user(user_id))

    with pytest.raises(HTTPException) as exc_info:
        await get_current_user(_credentials(token), db_session, redis_client)
    assert exc_info.value.status_code == 401


async def test_refresh_token_used_as_access_token_is_rejected():
    user_id = uuid.uuid4()
    refresh_token = create_refresh_token(str(user_id))
    redis_client = fakeredis_aioredis.FakeRedis(decode_responses=True)
    db_session = _FakeDBSession(_active_user(user_id))

    with pytest.raises(HTTPException) as exc_info:
        await get_current_user(_credentials(refresh_token), db_session, redis_client)
    assert exc_info.value.status_code == 401


async def test_unknown_user_is_rejected():
    user_id = uuid.uuid4()
    token = create_access_token(str(user_id), "a@b.com", "alice")
    redis_client = fakeredis_aioredis.FakeRedis(decode_responses=True)
    db_session = _FakeDBSession(None)

    with pytest.raises(HTTPException) as exc_info:
        await get_current_user(_credentials(token), db_session, redis_client)
    assert exc_info.value.status_code == 401


async def test_inactive_user_is_rejected():
    user_id = uuid.uuid4()
    token = create_access_token(str(user_id), "a@b.com", "alice")
    redis_client = fakeredis_aioredis.FakeRedis(decode_responses=True)
    inactive_user = _active_user(user_id)
    inactive_user.is_active = False
    db_session = _FakeDBSession(inactive_user)

    with pytest.raises(HTTPException) as exc_info:
        await get_current_user(_credentials(token), db_session, redis_client)
    assert exc_info.value.status_code == 401


async def test_revocation_check_fails_open_when_redis_unavailable(caplog):
    """A Redis outage during the revocation check must not deny a valid, active user."""
    user_id = uuid.uuid4()
    token = create_access_token(str(user_id), "a@b.com", "alice")
    db_session = _FakeDBSession(_active_user(user_id))

    with caplog.at_level("WARNING"):
        user = await get_current_user(_credentials(token), db_session, _UnavailableRedis())

    assert user.id == user_id
    assert "revocation_check_unavailable" in caplog.text
