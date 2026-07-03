import json
from datetime import datetime
from typing import Any, cast

import redis.asyncio as aioredis
from redis.exceptions import RedisError

from cache.exceptions import CacheUnavailableError

# All functions here assume a `decode_responses=True` client (the project-wide convention),
# so redis-py's broader `bytes | str` stub unions never occur at runtime — cast narrows them.
#
# Every function below catches redis-py's exceptions and re-raises CacheUnavailableError.
# This module never decides fallback behavior (e.g. "read from the DB instead") — it only
# normalizes low-level redis-py errors into one type the caller can catch, since only the
# caller (a Phase 6 router) knows whether a fallback exists for that particular read/write.

MAX_SESSIONS_PER_USER = 5
SESSION_LISTING_TTL = 86400  # 24 hours

SESSION_META_TTL = 3600  # 1 hour

MAX_MESSAGES_PER_SESSION = 20
SESSION_MESSAGES_TTL = 1800  # 30 minutes


def _sessions_key(user_id: Any) -> str:
    return f"user:{user_id}:sessions"


def _meta_key(session_id: Any) -> str:
    return f"session:{session_id}:meta"


def _messages_key(session_id: Any) -> str:
    return f"session:{session_id}:messages"


def _revoked_token_key(jti: str) -> str:
    return f"revoked_token:{jti}"


# A — User session listing (ZSET), last 5 sessions per user ordered by recency


async def add_session_to_listing(
    redis: aioredis.Redis, user_id: Any, session_id: Any, last_message_at: datetime
) -> None:
    key = _sessions_key(user_id)
    try:
        async with redis.pipeline(transaction=True) as pipe:
            pipe.zadd(key, {str(session_id): last_message_at.timestamp()})
            pipe.zremrangebyrank(key, 0, -(MAX_SESSIONS_PER_USER + 1))
            pipe.expire(key, SESSION_LISTING_TTL)
            await pipe.execute()
    except RedisError as e:
        raise CacheUnavailableError("add_session_to_listing failed") from e


async def get_recent_sessions(
    redis: aioredis.Redis, user_id: Any, limit: int = MAX_SESSIONS_PER_USER
) -> list[str]:
    key = _sessions_key(user_id)
    try:
        session_ids = await redis.zrevrange(key, 0, limit - 1)
        if session_ids:
            await redis.expire(key, SESSION_LISTING_TTL)
    except RedisError as e:
        raise CacheUnavailableError("get_recent_sessions failed") from e
    return cast(list[str], session_ids)


# B — Session metadata cache (HASH)


async def set_session_meta(redis: aioredis.Redis, session_id: Any, **fields: Any) -> None:
    key = _meta_key(session_id)
    try:
        async with redis.pipeline(transaction=True) as pipe:
            pipe.hset(key, mapping=fields)  # type: ignore[arg-type]  # redis-py's FieldT/EncodableT TypeVars don't resolve against a plain dict[str, str] here
            pipe.expire(key, SESSION_META_TTL)
            await pipe.execute()
    except RedisError as e:
        raise CacheUnavailableError("set_session_meta failed") from e


async def get_session_meta(redis: aioredis.Redis, session_id: Any) -> dict[str, str]:
    key = _meta_key(session_id)
    try:
        meta = await redis.hgetall(key)
        if meta:
            await redis.expire(key, SESSION_META_TTL)
    except RedisError as e:
        raise CacheUnavailableError("get_session_meta failed") from e
    return cast(dict[str, str], meta)


# C — Recent messages per session (LIST), last 20 messages


async def push_message(redis: aioredis.Redis, session_id: Any, message: dict) -> None:
    key = _messages_key(session_id)
    try:
        async with redis.pipeline(transaction=True) as pipe:
            pipe.rpush(key, json.dumps(message))
            pipe.ltrim(key, -MAX_MESSAGES_PER_SESSION, -1)
            pipe.expire(key, SESSION_MESSAGES_TTL)
            await pipe.execute()
    except RedisError as e:
        raise CacheUnavailableError("push_message failed") from e


async def get_recent_messages(redis: aioredis.Redis, session_id: Any) -> list[dict]:
    key = _messages_key(session_id)
    try:
        raw_messages = await redis.lrange(key, 0, -1)
        if raw_messages:
            await redis.expire(key, SESSION_MESSAGES_TTL)
    except RedisError as e:
        raise CacheUnavailableError("get_recent_messages failed") from e
    return [json.loads(m) for m in raw_messages]


# D — JWT access token revocation (STRING), TTL = remaining token lifetime


async def revoke_token(redis: aioredis.Redis, jti: str, ttl_seconds: int) -> None:
    if ttl_seconds > 0:
        try:
            await redis.set(_revoked_token_key(jti), "1", ex=ttl_seconds, nx=True)
        except RedisError as e:
            raise CacheUnavailableError("revoke_token failed") from e


async def is_token_revoked(redis: aioredis.Redis, jti: str) -> bool:
    try:
        return bool(await redis.exists(_revoked_token_key(jti)))
    except RedisError as e:
        raise CacheUnavailableError("is_token_revoked failed") from e
