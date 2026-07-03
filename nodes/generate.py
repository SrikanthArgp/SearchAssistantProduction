from typing import Any, Dict

from tenacity import retry, stop_after_attempt, wait_exponential

from chains.generation import generation_chain
from state import GraphState


@retry(stop=stop_after_attempt(2), wait=wait_exponential(min=1, max=4), reraise=True)
def _call_generation(context, question: str) -> str:
    return generation_chain.invoke({"context": context, "question": question})


def generate(state: GraphState) -> Dict[str, Any]:
    print("---GENERATE---")
    question = state["question"]
    documents = state["documents"]

    # Unlike retrieve/web_search, generate() has no lower-fidelity fallback to degrade
    # to — it IS the answer. After 2 attempts, let the exception propagate up through
    # the graph so main.py's top-level try/except can report it cleanly, instead of
    # returning a canned message that would likely fail hallucination grading and
    # loop back here anyway.
    generation = _call_generation(documents, question)
    return {"documents": documents, "question": question, "generation": generation}
