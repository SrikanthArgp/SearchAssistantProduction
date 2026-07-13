import logging
import time
from datetime import datetime, timezone

import redis.asyncio as aioredis
from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials
from jose import JWTError
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.dependencies import enforce_auth_rate_limit, get_current_user, get_db, get_redis
from api.schemas.auth import (
    AuthResponse,
    LoginRequest,
    LogoutRequest,
    RefreshRequest,
    RegisterRequest,
    TokenResponse,
    UserResponse,
)
from auth.dependencies import bearer_scheme, extract_bearer_token
from auth.jwt import (
    ACCESS_TOKEN_EXPIRE_MINUTES,
    create_access_token,
    create_refresh_token,
    decode_token,
)
from auth.password import hash_password, verify_password
from cache.exceptions import CacheUnavailableError
from cache.sessions import revoke_token as cache_revoke_token
from db.crud import refresh_tokens as refresh_tokens_crud
from db.crud import users as users_crud
from db.models import User

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/auth", tags=["auth"])


def _seconds_until(exp_timestamp: int) -> int:
    return max(0, int(exp_timestamp - time.time()))


async def _revoke_in_cache(redis: aioredis.Redis, jti: str, exp_timestamp: int) -> None:
    try:
        await cache_revoke_token(redis, jti, _seconds_until(exp_timestamp))
    except CacheUnavailableError:
        # DB-side revocation (refresh_tokens.revoked) is authoritative for refresh tokens;
        # this is a fast-path cache of it. Access tokens have no DB row, so an unreachable
        # Redis here means the access token stays valid until its own expiry (fail open,
        # same reasoning as the Phase 3 revocation check).
        pass


async def _issue_token_pair(db: AsyncSession, user: User) -> TokenResponse:
    access_token = create_access_token(str(user.id), user.email, user.username)
    refresh_token = create_refresh_token(str(user.id))
    refresh_claims = decode_token(refresh_token)
    expires_at = datetime.fromtimestamp(refresh_claims["exp"], tz=timezone.utc)
    await refresh_tokens_crud.create(db, user.id, refresh_token, expires_at=expires_at)
    return TokenResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        expires_in=ACCESS_TOKEN_EXPIRE_MINUTES * 60,
    )


@router.post("/register", response_model=AuthResponse, status_code=status.HTTP_201_CREATED)
async def register(
    payload: RegisterRequest,
    db: AsyncSession = Depends(get_db),
    _rate_limit: None = Depends(enforce_auth_rate_limit),
) -> AuthResponse:
    try:
        user = await users_crud.create(
            db,
            email=payload.email,
            username=payload.username,
            hashed_password=hash_password(payload.password),
        )
    except IntegrityError as e:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="Email or username already registered"
        ) from e

    tokens = await _issue_token_pair(db, user)
    return AuthResponse(tokens=tokens, user=UserResponse.model_validate(user))


@router.post("/login", response_model=AuthResponse)
async def login(
    payload: LoginRequest,
    db: AsyncSession = Depends(get_db),
    _rate_limit: None = Depends(enforce_auth_rate_limit),
) -> AuthResponse:
    invalid = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid email or password"
    )
    user = await users_crud.get_by_email(db, payload.email)
    if (
        user is None
        or not user.is_active
        or not verify_password(payload.password, user.hashed_password)
    ):
        raise invalid

    tokens = await _issue_token_pair(db, user)
    logger.info("auth_login", extra={"user_id": str(user.id)})
    return AuthResponse(tokens=tokens, user=UserResponse.model_validate(user))


@router.post("/refresh", response_model=TokenResponse)
async def refresh(
    payload: RefreshRequest,
    db: AsyncSession = Depends(get_db),
    redis: aioredis.Redis = Depends(get_redis),
) -> TokenResponse:
    invalid = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid or expired refresh token"
    )
    try:
        claims = decode_token(payload.refresh_token)
    except JWTError:
        raise invalid
    if claims.get("type") != "refresh":
        raise invalid

    row = await refresh_tokens_crud.get_active_by_token(db, payload.refresh_token)
    if row is None:
        raise invalid

    user = await users_crud.get_by_id(db, row.user_id)
    if user is None or not user.is_active:
        raise invalid

    await refresh_tokens_crud.revoke(db, row)
    await _revoke_in_cache(redis, claims["jti"], claims["exp"])

    logger.info("auth_token_refreshed", extra={"user_id": str(user.id)})
    return await _issue_token_pair(db, user)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(
    payload: LogoutRequest,
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
    redis: aioredis.Redis = Depends(get_redis),
) -> None:
    # Re-extract the same way get_current_user did (X-Auth-Token first, Authorization Bearer
    # fallback) rather than trusting credentials.credentials directly — bearer_scheme is
    # auto_error=False, so credentials can legitimately be None here (e.g. a request that only
    # carried X-Auth-Token, the case on the streaming Lambda's OAC-signed path).
    token = extract_bearer_token(request, credentials)
    try:
        access_claims = decode_token(token) if token else None
        if access_claims:
            await _revoke_in_cache(redis, access_claims["jti"], access_claims["exp"])
    except JWTError:
        pass  # already validated by get_current_user; this can't realistically happen

    if payload.refresh_token:
        row = await refresh_tokens_crud.get_active_by_token(db, payload.refresh_token)
        if row is not None and row.user_id == current_user.id:
            await refresh_tokens_crud.revoke(db, row)
            try:
                refresh_claims = decode_token(payload.refresh_token)
                await _revoke_in_cache(redis, refresh_claims["jti"], refresh_claims["exp"])
            except JWTError:
                pass

    logger.info("auth_logout", extra={"user_id": str(current_user.id)})


@router.get("/me", response_model=UserResponse)
async def me(current_user: User = Depends(get_current_user)) -> UserResponse:
    return UserResponse.model_validate(current_user)
