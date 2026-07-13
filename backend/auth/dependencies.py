import logging
import os
import uuid
from collections.abc import AsyncGenerator

import redis.asyncio as aioredis
import structlog
from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import JWTError
from redis.exceptions import RedisError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from auth.jwt import decode_token
from db.base import async_session_factory
from db.models import User

logger = logging.getLogger(__name__)

bearer_scheme = HTTPBearer(auto_error=False)


async def get_db_session() -> AsyncGenerator[AsyncSession, None]:
    async with async_session_factory() as session:
        yield session


async def get_redis_client() -> aioredis.Redis:
    # Same fast-fail timeouts as api/main.py's app.state.redis - this default provider is
    # normally replaced via app.dependency_overrides (see api/main.py), but should degrade
    # just as fast as the real one on the rare path where it isn't.
    return aioredis.from_url(
        os.environ["REDIS_URL"],
        decode_responses=True,
        socket_connect_timeout=2,
        socket_timeout=2,
    )


def extract_bearer_token(
    request: Request, credentials: HTTPAuthorizationCredentials | None
) -> str | None:
    # X-Auth-Token takes priority over the standard Authorization header. On the streaming
    # Lambda's Function URL (behind CloudFront's Origin Access Control, AWS_IAM auth), CloudFront
    # overwrites Authorization with its own AWS SigV4 signature before the request reaches this
    # app — this app's own bearer token can't survive in that header on that path, only on this
    # custom one (see infra/lambda-gate/cloudfront.tf's OAC comments). The buffered/API-Gateway
    # path has no such conflict, but the frontend sends both headers everywhere so this same
    # extraction works unconditionally, regardless of which origin actually served the request.
    # bearer_scheme is auto_error=False (not the HTTPBearer default) specifically so credentials
    # can be None here rather than FastAPI auto-403ing before this fallback ever runs.
    token = request.headers.get("X-Auth-Token")
    if token is not None:
        return token
    return credentials.credentials if credentials is not None else None


async def get_current_user(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    db_session: AsyncSession = Depends(get_db_session),
    redis_client: aioredis.Redis = Depends(get_redis_client),
) -> User:
    unauthorized = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED, detail="Could not validate credentials"
    )

    token = extract_bearer_token(request, credentials)
    if token is None:
        raise unauthorized

    try:
        claims = decode_token(token)
    except JWTError:
        raise unauthorized

    if claims.get("type") != "access":
        raise unauthorized

    jti = claims.get("jti")
    if jti:
        try:
            if await redis_client.exists(f"revoked_token:{jti}"):
                logger.info("auth_revoked_token_rejected", extra={"jti": jti})
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

    structlog.contextvars.bind_contextvars(user_id=str(user.id))
    return user
