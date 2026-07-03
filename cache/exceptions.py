class CacheUnavailableError(Exception):
    """Raised when Redis is unreachable or errors out.

    Deliberately generic: callers (e.g. Phase 6 routers) decide what to do about
    a cache outage (typically: fall back to the database, same as a cache miss).
    This module only normalizes redis-py's various exception types into one the
    rest of the app can catch without importing redis internals.
    """
