import logging

from langfuse.langchain import CallbackHandler

logger = logging.getLogger(__name__)


def get_langfuse_handler() -> CallbackHandler | None:
    """Build a Langfuse callback handler from LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY /
    LANGFUSE_HOST in the environment.

    Returns None instead of raising if Langfuse isn't configured or unreachable, so tracing
    being unavailable never blocks a graph run (see Resilience & Crash Prevention in plan.md).
    Callers should skip adding the handler to callbacks when this returns None.
    """
    try:
        return CallbackHandler()
    except Exception:
        logger.warning("langfuse_handler_unavailable", exc_info=True)
        return None
