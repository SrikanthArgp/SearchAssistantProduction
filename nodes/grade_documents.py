import logging
from typing import Any, Dict

from tenacity import retry, stop_after_attempt, wait_exponential

from chains.retrieval_grader import retrieval_grader
from state import GraphState

logger = logging.getLogger(__name__)


@retry(stop=stop_after_attempt(2), wait=wait_exponential(min=1, max=4), reraise=False)
def _grade_document(question: str, content: str):
    return retrieval_grader.invoke({"question": question, "document": content})


def grade_documents(state: GraphState) -> Dict[str, Any]:
    """
    Determines whether the retrieved documents are relevant to the question
    If any document is not relevant, we will set a flag to run web search

    Args:
        state (dict): The current graph state

    Returns:
        state (dict): Filtered out irrelevant documents and updated web_search state
    """

    print("---CHECK DOCUMENT RELEVANCE TO QUESTION---")
    question = state["question"]
    documents = state["documents"]

    filtered_docs = []
    web_search = False
    for d in documents:
        try:
            grade = _grade_document(question, d.page_content).binary_score
        except Exception:
            logger.warning("retrieval_grading_failed", exc_info=True)
            # Can't confirm relevance — treat this doc like an irrelevant one and
            # fall back to web search rather than trusting an unscored document.
            print("---GRADE: UNAVAILABLE, TREATING AS NOT RELEVANT---")
            web_search = True
            continue

        if grade.lower() == "yes":
            print("---GRADE: DOCUMENT RELEVANT---")
            filtered_docs.append(d)
        else:
            print("---GRADE: DOCUMENT NOT RELEVANT---")
            web_search = True
            continue
    return {"documents": filtered_docs, "question": question, "web_search": web_search}
