"""Failure-path tests for Phase 5's retry/degrade wrapping around external calls.

None of these hit a real LLM/Tavily/Chroma call — each patches the tenacity-wrapped
`_call_*`/`_grade_*`/`_route_question` helper (the function that owns the retry) to
always raise, simulating retries being exhausted, then asserts the documented degrade
behavior instead of a raised/uncaught exception (except for generate(), whose
documented behavior is to propagate after retries are exhausted — see nodes/generate.py).

The chain/tool objects themselves (retriever, web_search_tool, generation_chain, ...)
are pydantic models that reject ad hoc attribute patching, so the wrapper functions —
plain module-level functions — are the right patch point anyway.
"""

import importlib

from langchain.schema import Document

import graph

# `nodes/__init__.py` does `from nodes.retrieve import retrieve`, which rebinds the
# `nodes.retrieve` package attribute to the *function*, shadowing the submodule of the
# same name. `import nodes.retrieve as x` would silently resolve to that function
# instead of the module, so `_call_retriever` etc. wouldn't exist on it. Go through
# `importlib.import_module` (backed by `sys.modules`) to get the real submodule.
retrieve_module = importlib.import_module("nodes.retrieve")
web_search_module = importlib.import_module("nodes.web_search")
generate_module = importlib.import_module("nodes.generate")
grade_documents_module = importlib.import_module("nodes.grade_documents")


class _StubScore:
    def __init__(self, binary_score):
        self.binary_score = binary_score


def _always_raises(*_args, **_kwargs):
    raise ConnectionError("simulated external service outage")


def test_retrieve_degrades_to_empty_documents_on_chroma_failure(monkeypatch):
    monkeypatch.setattr(retrieve_module, "_call_retriever", _always_raises)

    result = retrieve_module.retrieve({"question": "agent memory"})

    assert result["documents"] == []
    assert result["question"] == "agent memory"


def test_web_search_degrades_to_empty_results_on_tavily_failure(monkeypatch):
    monkeypatch.setattr(web_search_module, "_call_tavily", _always_raises)

    result = web_search_module.web_search({"question": "how to make pizza"})

    assert len(result["documents"]) == 1
    assert result["documents"][0].page_content == ""


def test_web_search_appends_to_existing_documents_on_failure(monkeypatch):
    monkeypatch.setattr(web_search_module, "_call_tavily", _always_raises)
    existing = [Document(page_content="already retrieved")]

    result = web_search_module.web_search(
        {"question": "how to make pizza", "documents": existing}
    )

    assert len(result["documents"]) == 2
    assert result["documents"][0].page_content == "already retrieved"
    assert result["documents"][1].page_content == ""


def test_generate_reraises_after_retries_exhausted(monkeypatch):
    monkeypatch.setattr(generate_module, "_call_generation", _always_raises)

    try:
        generate_module.generate(
            {"question": "agent memory", "documents": [Document(page_content="x")]}
        )
        assert False, "expected generate() to propagate the exception"
    except ConnectionError:
        pass


def test_grade_documents_degrades_to_web_search_true_on_grader_failure(monkeypatch):
    monkeypatch.setattr(grade_documents_module, "_grade_document", _always_raises)

    result = grade_documents_module.grade_documents(
        {"question": "agent memory", "documents": [Document(page_content="x")]}
    )

    assert result["documents"] == []
    assert result["web_search"] is True


def test_route_question_defaults_to_websearch_on_router_failure(monkeypatch):
    monkeypatch.setattr(graph, "_route_question", _always_raises)

    decision = graph.route_question({"question": "agent memory"})

    assert decision == "websearch"


def test_grade_generation_accepts_on_hallucination_grader_failure(monkeypatch):
    monkeypatch.setattr(graph, "_grade_hallucination", _always_raises)

    decision = graph.grade_generation_grounded_in_documents_and_question(
        {
            "question": "agent memory",
            "documents": [Document(page_content="x")],
            "generation": "some answer",
        }
    )

    assert decision == "useful"


def test_grade_generation_accepts_on_answer_grader_failure(monkeypatch):
    monkeypatch.setattr(
        graph, "_grade_hallucination", lambda *_a, **_k: _StubScore(True)
    )
    monkeypatch.setattr(graph, "_grade_answer", _always_raises)

    decision = graph.grade_generation_grounded_in_documents_and_question(
        {
            "question": "agent memory",
            "documents": [Document(page_content="x")],
            "generation": "some answer",
        }
    )

    assert decision == "useful"
