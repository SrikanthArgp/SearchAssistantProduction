import logging
from typing import Any, Dict

from tenacity import retry, stop_after_attempt, wait_exponential

from state import GraphState
from ingestion import retriever

logger = logging.getLogger(__name__)


@retry(stop=stop_after_attempt(2), wait=wait_exponential(min=1, max=4), reraise=False)
def _call_retriever(question: str):
    return retriever.invoke(question)


def retrieve(state: GraphState) -> Dict[str, Any]:
    print("---RETRIEVE---")
    question = state["question"]

    try:
        documents = _call_retriever(question)
    except Exception:
        logger.warning("retrieve_failed", exc_info=True)
        # Chroma unreachable/erroring — degrade to no documents so grade_documents/
        # generate still run rather than crashing the whole graph run.
        documents = []

    return {"documents": documents, "question": question}
