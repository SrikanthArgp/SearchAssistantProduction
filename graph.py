import logging

from dotenv import load_dotenv

load_dotenv()

from langgraph.graph import END, START, StateGraph
from tenacity import retry, stop_after_attempt, wait_exponential

from chains.answer_grader import answer_grader
from chains.hallucination_grader import hallucination_grader
from chains.router import question_router, RouteQuery
from consts import GENERATE, GRADE_DOCUMENTS, RETRIEVE, WEBSEARCH
from nodes import generate, grade_documents, retrieve, web_search
from state import GraphState

logger = logging.getLogger(__name__)

_RETRY = dict(stop=stop_after_attempt(2), wait=wait_exponential(min=1, max=4), reraise=False)


@retry(**_RETRY)
def _route_question(question: str) -> RouteQuery:
    return question_router.invoke({"question": question})  # type: ignore


@retry(**_RETRY)
def _grade_hallucination(documents, generation):
    return hallucination_grader.invoke(
        {"documents": documents, "generation": generation}
    )


@retry(**_RETRY)
def _grade_answer(question, generation):
    return answer_grader.invoke({"question": question, "generation": generation})


def decide_to_generate(state):
    print("---ASSESS GRADED DOCUMENTS---")

    if state["web_search"]:
        print(
            "---DECISION: NOT ALL DOCUMENTS ARE NOT RELEVANT TO QUESTION, INCLUDE WEB SEARCH---"
        )
        return WEBSEARCH
    else:
        print("---DECISION: GENERATE---")
        return GENERATE


def grade_generation_grounded_in_documents_and_question(state: GraphState) -> str:
    print("---CHECK HALLUCINATIONS---")
    question = state["question"]
    documents = state["documents"]
    generation = state["generation"]

    try:
        hallucination_grade = _grade_hallucination(documents, generation).binary_score
    except Exception:
        logger.warning("hallucination_grading_failed", exc_info=True)
        # Can't verify groundedness — accept the generation rather than looping
        # indefinitely between generate/websearch on a degraded grader.
        print("---HALLUCINATION CHECK UNAVAILABLE, ACCEPTING GENERATION---")
        return "useful"

    if hallucination_grade:
        print("---DECISION: GENERATION IS GROUNDED IN DOCUMENTS---")
        print("---GRADE GENERATION vs QUESTION---")
        try:
            answer_grade = _grade_answer(question, generation).binary_score
        except Exception:
            logger.warning("answer_grading_failed", exc_info=True)
            print("---ANSWER CHECK UNAVAILABLE, ACCEPTING GENERATION---")
            return "useful"
        if answer_grade:
            print("---DECISION: GENERATION ADDRESSES QUESTION---")
            return "useful"
        else:
            print("---DECISION: GENERATION DOES NOT ADDRESS QUESTION---")
            return "not useful"
    else:
        print("---DECISION: GENERATION IS NOT GROUNDED IN DOCUMENTS, RE-TRY---")
        return "not supported"


def route_question(state: GraphState) -> str:
    print("---ROUTE QUESTION---")
    question = state["question"]
    try:
        source = _route_question(question)
    except Exception:
        logger.warning("routing_failed", exc_info=True)
        print("---ROUTING UNAVAILABLE, DEFAULTING TO WEB SEARCH---")
        return WEBSEARCH

    if source.datasource == WEBSEARCH:
        print("---ROUTE QUESTION TO WEB SEARCH---")
        return WEBSEARCH
    elif source.datasource == "vectorstore":
        print("---ROUTE QUESTION TO RAG---")
        return RETRIEVE


workflow = StateGraph(GraphState)
workflow.add_node(RETRIEVE, retrieve)
workflow.add_node(GRADE_DOCUMENTS, grade_documents)
workflow.add_node(GENERATE, generate)
workflow.add_node(WEBSEARCH, web_search)


workflow.add_conditional_edges(
    START,
    route_question,
    {
        WEBSEARCH: WEBSEARCH,
        RETRIEVE: RETRIEVE,
    },
)
workflow.add_edge(RETRIEVE, GRADE_DOCUMENTS)
workflow.add_conditional_edges(
    GRADE_DOCUMENTS,
    decide_to_generate,
    {
        WEBSEARCH: WEBSEARCH,
        GENERATE: GENERATE,
    },
)
workflow.add_edge(WEBSEARCH, GENERATE)
workflow.add_conditional_edges(
    GENERATE,
    grade_generation_grounded_in_documents_and_question,
    {
        "not supported": GENERATE,
        "useful": END,
        "not useful": WEBSEARCH,
    },
)


def create_app(checkpointer):
    """Compile and return the CRAG graph with the given checkpointer."""
    return workflow.compile(checkpointer=checkpointer)
