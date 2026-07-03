import logging
import os
import uuid
from collections.abc import AsyncGenerator

import redis.asyncio as aioredis
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import JWTError
from redis.exceptions import RedisError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from auth.jwt import decode_token
from db.base import async_session_factory
from db.models import User

logger = logging.getLogger(__name__)

bearer_scheme = HTTPBearer()


async def get_db_session() -> AsyncGenerator[AsyncSession, None]:
    async with async_session_factory() as session:
        yield session


async def get_redis_client() -> aioredis.Redis:
    return aioredis.from_url(os.environ["REDIS_URL"], decode_responses=True)


async def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(bearer_scheme),
    db_session: AsyncSession = Depends(get_db_session),
    redis_client: aioredis.Redis = Depends(get_redis_client),
) -> User:
    unauthorized = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED, detail="Could not validate credentials"
    )

    try:
        claims = decode_token(credentials.credentials)
    except JWTError:
        raise unauthorized

    if claims.get("type") != "access":
        raise unauthorized

    jti = claims.get("jti")
    if jti:
        try:
            if await redis_client.exists(f"revoked_token:{jti}"):
                raise unauthorized
        except RedisError:
            # Fail open: the JWT signature/expiry check above is the primary security
            # control. Revocation is defense-in-depth for the logged-out-but-unexpired
            # case, so a Redis outage should degrade auth availability, not deny it.
            logger.warning("revocation_check_unavailable", extra={"jti": jti})

    try:
        user_id = uuid.UUID(claims.get("sub", ""))
    except ValueError:
        raise unauthorized

    result = await db_session.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None or not user.is_active:
        raise unauthorized

    return user
