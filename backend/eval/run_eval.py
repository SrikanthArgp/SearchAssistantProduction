"""CLI runner for the Phase 9 eval suite.

    python -m eval.run_eval
    python -m eval.run_eval --experiment-name baseline-v1

Exits 1 if any RAGAS metric falls below its threshold (eval/metrics.py THRESHOLDS),
so this is CI-gateable.
"""

import argparse
import sys
from collections import defaultdict
from datetime import datetime, timezone

from dotenv import load_dotenv

load_dotenv()

from eval.langfuse_eval import run_eval
from eval.metrics import THRESHOLDS


def _default_experiment_name() -> str:
    return f"eval-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}"


def _per_metric_averages(experiment) -> dict[str, float]:
    totals: dict[str, list[float]] = defaultdict(list)
    for item_result in experiment.item_results:
        for evaluation in item_result.evaluations:
            totals[evaluation.name].append(evaluation.value)
    return {name: sum(values) / len(values) for name, values in totals.items()}


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the CRAG RAGAS eval suite against Langfuse.")
    parser.add_argument("--experiment-name", default=_default_experiment_name())
    args = parser.parse_args()

    experiment = run_eval(args.experiment_name)
    averages = _per_metric_averages(experiment)

    print(f"\n## Eval results — {args.experiment_name}\n")
    print("| Metric | Score | Threshold | Result |")
    print("|---|---|---|---|")
    passed = True
    for metric, threshold in THRESHOLDS.items():
        score = averages.get(metric)
        if score is None:
            print(f"| {metric} | n/a | {threshold} | SKIPPED |")
            continue
        ok = score >= threshold
        passed = passed and ok
        print(f"| {metric} | {score:.3f} | {threshold} | {'PASS' if ok else 'FAIL'} |")

    if experiment.dataset_run_url:
        print(f"\nLangfuse dataset run: {experiment.dataset_run_url}")

    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
