import logging
from typing import Any, Dict

from langchain.schema import Document
from langchain_community.tools.tavily_search import TavilySearchResults
from tenacity import retry, stop_after_attempt, wait_exponential

from state import GraphState

logger = logging.getLogger(__name__)

web_search_tool = TavilySearchResults(k=3)


@retry(stop=stop_after_attempt(2), wait=wait_exponential(min=1, max=4), reraise=False)
def _call_tavily(question: str):
    return web_search_tool.invoke({"query": question})


def web_search(state: GraphState) -> Dict[str, Any]:
    print("---WEB SEARCH---")
    question = state["question"]
    documents = state.get("documents")

    try:
        docs = _call_tavily(question)
    except Exception:
        logger.warning("web_search_failed", exc_info=True)
        # Tavily unreachable/erroring — degrade to no results so generate() still
        # runs on whatever documents already exist rather than crashing.
        docs = []

    web_results = "\n".join([d["content"] for d in docs])
    web_results = Document(page_content=web_results)
    if documents is not None:
        documents.append(web_results)
    else:
        documents = [web_results]
    return {"documents": documents, "question": question}
