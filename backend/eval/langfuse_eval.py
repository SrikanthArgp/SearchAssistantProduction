"""Langfuse dataset + experiment wiring for the Phase 9 eval suite.

Deviates from the plan's original create_or_get_dataset/run_target/score_and_push trio:
the installed langfuse SDK's `dataset.run_experiment(task=..., evaluators=...)` does the same
job (per-item task execution, per-item scoring, dataset-run linking, `dataset_run_url`) with
far less custom code. Verified directly against the installed package (`langfuse==4.13.0`)
rather than assuming the plan's `item.get_langchain_handler(run_name=...)` sketch (written
against an older SDK version) still matched — see plan.md's Phase 9 note (2026-07-05).
"""

import logging

from langfuse import Evaluation, Langfuse
from langgraph.checkpoint.memory import MemorySaver

from eval.dataset import DATASET
from eval.metrics import score_sample
from multi_agent.graph import create_app
from multi_agent.observability.langfuse_client import get_langfuse_handler

logger = logging.getLogger(__name__)

DATASET_NAME = "crag-eval-25"

langfuse = Langfuse()


def create_or_get_dataset() -> None:
    """Idempotent: create_dataset_item upserts by `id`, so re-running this against an
    already-populated dataset just re-upserts the same 25 items."""
    try:
        langfuse.create_dataset(name=DATASET_NAME)
    except Exception:
        logger.info("dataset_already_exists", extra={"dataset_name": DATASET_NAME})

    for i, item in enumerate(DATASET):
        langfuse.create_dataset_item(
            dataset_name=DATASET_NAME,
            id=f"item-{i:02d}",
            input={"question": item.question, "routing": item.routing},
            expected_output=item.ground_truth,
        )


async def task(*, item, **kwargs) -> dict:
    question = item.input["question"]
    handler = get_langfuse_handler()
    callbacks = [handler] if handler is not None else []
    app = create_app(MemorySaver())
    config = {"configurable": {"thread_id": f"eval-{hash(question)}"}, "callbacks": callbacks}
    result = app.invoke({"question": question}, config=config)
    contexts = [d.page_content for d in result.get("documents", [])]
    return {"answer": result.get("generation", ""), "contexts": contexts}


async def evaluator(*, output: dict, input: dict, expected_output=None, **kwargs) -> list[Evaluation]:
    scores = await score_sample(
        question=input["question"],
        answer=output["answer"],
        contexts=output["contexts"] or [""],
        ground_truth=expected_output,
    )
    return [Evaluation(name=name, value=value) for name, value in scores.items()]


def run_eval(experiment_name: str):
    create_or_get_dataset()
    dataset = langfuse.get_dataset(DATASET_NAME)
    return dataset.run_experiment(
        name=experiment_name,
        task=task,
        evaluators=[evaluator],
    )
