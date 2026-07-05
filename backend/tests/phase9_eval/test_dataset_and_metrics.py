"""Fast, no-LLM-calls checks: dataset shape and threshold config, before burning API
calls on the real eval run. Constructing eval.metrics does instantiate ChatOpenAI/
OpenAIEmbeddings (same as every multi_agent.chains module), but nothing here invokes them."""

from eval.dataset import DATASET, VECTORSTORE_ITEMS, WEBSEARCH_ITEMS
from eval.metrics import THRESHOLDS


def test_dataset_has_25_items() -> None:
    assert len(DATASET) == 25


def test_dataset_routing_split() -> None:
    assert len(VECTORSTORE_ITEMS) == 20
    assert len(WEBSEARCH_ITEMS) == 5
    assert all(item.ground_truth is not None for item in VECTORSTORE_ITEMS)
    assert all(item.ground_truth is None for item in WEBSEARCH_ITEMS)


def test_thresholds_has_all_4_metrics() -> None:
    assert set(THRESHOLDS.keys()) == {
        "faithfulness",
        "answer_relevancy",
        "context_recall",
        "context_precision",
    }
