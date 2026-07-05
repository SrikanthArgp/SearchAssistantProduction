"""RAGAS metric instances + threshold gate for the Phase 9 eval suite.

Targets ragas 0.4.x's current (non-deprecated) API — `SingleTurnSample` +
`LangchainLLMWrapper`/`single_turn_ascore` (what plan.md and pyproject.toml's `ragas==0.2.*`
pin originally assumed) no longer exists in the installed version: `LangchainLLMWrapper` is
deprecated and isn't an `InstructorBaseRagasLLM`, so it's rejected by the 0.4.x metric
classes at runtime. Verified directly against the installed package (`ragas==0.4.3`) rather
than assuming the pin was still accurate — see plan.md's Phase 9 note (2026-07-05) for the
version-drift writeup and pyproject.toml's corrected pin.
"""

from openai import AsyncOpenAI
from ragas.embeddings import OpenAIEmbeddings
from ragas.llms import llm_factory
from ragas.metrics.collections import (
    AnswerRelevancy,
    ContextPrecision,
    ContextRecall,
    Faithfulness,
)

_client = AsyncOpenAI()
_evaluator_llm = llm_factory("gpt-4o-mini", client=_client)
_evaluator_embeddings = OpenAIEmbeddings(client=_client)

faithfulness = Faithfulness(llm=_evaluator_llm)
answer_relevancy = AnswerRelevancy(llm=_evaluator_llm, embeddings=_evaluator_embeddings)
context_recall = ContextRecall(llm=_evaluator_llm)
context_precision = ContextPrecision(llm=_evaluator_llm)

THRESHOLDS = {
    "faithfulness": 0.75,
    "answer_relevancy": 0.75,
    "context_recall": 0.65,
    "context_precision": 0.65,
}


async def score_sample(
    question: str, answer: str, contexts: list[str], ground_truth: str | None
) -> dict[str, float]:
    """context_recall/context_precision need a reference (ground_truth) and are skipped
    for the 5 websearch dataset items, which don't have one."""
    scores = {
        "faithfulness": (
            await faithfulness.ascore(
                user_input=question, response=answer, retrieved_contexts=contexts
            )
        ).value,
        "answer_relevancy": (
            await answer_relevancy.ascore(user_input=question, response=answer)
        ).value,
    }
    if ground_truth is not None:
        scores["context_recall"] = (
            await context_recall.ascore(
                user_input=question, reference=ground_truth, retrieved_contexts=contexts
            )
        ).value
        scores["context_precision"] = (
            await context_precision.ascore(
                user_input=question, reference=ground_truth, retrieved_contexts=contexts
            )
        ).value
    return scores
