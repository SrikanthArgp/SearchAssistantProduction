"""25-item eval dataset for the CRAG graph, drawn from the 3 ingested Lilian Weng blog posts.

20 items route to `vectorstore` (topics covered by the corpus: agents, prompt engineering,
adversarial attacks on LLMs) and carry a `ground_truth` answer. 5 items route to `websearch`
(topics outside the corpus on purpose) and carry `ground_truth=None`, since there's no fixed
answer to check RAGAS's ground-truth-dependent metrics against for those.
"""

from dataclasses import dataclass
from typing import Literal, Optional


@dataclass(frozen=True)
class EvalItem:
    question: str
    routing: Literal["vectorstore", "websearch"]
    ground_truth: Optional[str]


DATASET: list[EvalItem] = [
    # --- agents (2023-06-23-agent) ---
    EvalItem(
        question="What is task decomposition and how does Chain of Thought relate to it?",
        routing="vectorstore",
        ground_truth=(
            "Task decomposition breaks a complex task into smaller, simpler sub-tasks. "
            "Chain of Thought (CoT) is a prompting technique that instructs the model to "
            "'think step by step', decomposing hard tasks into a sequence of intermediate "
            "reasoning steps."
        ),
    ),
    EvalItem(
        question="How does Tree of Thoughts extend Chain of Thought prompting?",
        routing="vectorstore",
        ground_truth=(
            "Tree of Thoughts extends Chain of Thought by exploring multiple reasoning paths "
            "at each step, creating a tree structure of thoughts that is evaluated via a "
            "classifier or majority vote to decide which branch to continue."
        ),
    ),
    EvalItem(
        question="What is the ReAct framework for LLM agents?",
        routing="vectorstore",
        ground_truth=(
            "ReAct integrates reasoning and acting by having the model cycle through "
            "thought, action, and observation steps, interleaving reasoning traces with "
            "task-specific actions."
        ),
    ),
    EvalItem(
        question="What are the three types of memory described for LLM-powered agents, and what does each map to?",
        routing="vectorstore",
        ground_truth=(
            "Sensory memory maps to embedding representations of raw inputs, short-term/"
            "working memory maps to in-context learning within the model's context window, "
            "and long-term memory maps to an external vector store that supports fast "
            "retrieval of information."
        ),
    ),
    EvalItem(
        question="What is Maximum Inner Product Search (MIPS) used for in agent memory systems?",
        routing="vectorstore",
        ground_truth=(
            "MIPS is used to efficiently retrieve relevant information from an external "
            "vector store, typically via approximate nearest neighbor algorithms such as "
            "LSH, ANNOY, HNSW, FAISS, or ScaNN, to give an agent fast access to long-term "
            "memory."
        ),
    ),
    EvalItem(
        question="What is a MRKL system in the context of LLM tool use?",
        routing="vectorstore",
        ground_truth=(
            "MRKL is a neuro-symbolic architecture where the LLM acts as a router that "
            "sends a query to one of several specialized expert modules, which may be "
            "either neural or symbolic tools."
        ),
    ),
    EvalItem(
        question="What are some case studies of LLM-powered autonomous agents mentioned, such as AutoGPT or ChemCrow?",
        routing="vectorstore",
        ground_truth=(
            "ChemCrow augments an LLM with 13 expert chemistry tools for tasks like drug "
            "discovery; Generative Agents simulates 25 virtual characters with memory "
            "streams and reflection to produce emergent social behavior; AutoGPT and "
            "GPT-Engineer are proof-of-concept demos of autonomous task and code execution."
        ),
    ),
    # --- prompt engineering (2023-03-15-prompt-engineering) ---
    EvalItem(
        question="What is the difference between zero-shot and few-shot prompting?",
        routing="vectorstore",
        ground_truth=(
            "Zero-shot prompting gives the model the task description with no examples, "
            "while few-shot prompting provides several high-quality demonstrations of the "
            "task before asking the model to perform it, generally improving performance "
            "at the cost of more tokens."
        ),
    ),
    EvalItem(
        question="What is instruction prompting?",
        routing="vectorstore",
        ground_truth=(
            "Instruction prompting relies on a model that has been finetuned on "
            "(instruction, input, output) tuples so it can follow a direct task "
            "description without needing few-shot examples, reducing token usage."
        ),
    ),
    EvalItem(
        question="What is self-consistency sampling in prompting?",
        routing="vectorstore",
        ground_truth=(
            "Self-consistency sampling generates multiple outputs at a higher temperature "
            "and then selects the best candidate via majority voting or a task-specific "
            "validation method."
        ),
    ),
    EvalItem(
        question="What does the Automatic Prompt Engineer (APE) method do?",
        routing="vectorstore",
        ground_truth=(
            "APE generates candidate instructions by prompting a model, scores each "
            "candidate on training data, and iteratively improves the top candidates "
            "through semantic variation."
        ),
    ),
    EvalItem(
        question="What is in-context learning?",
        routing="vectorstore",
        ground_truth=(
            "In-context learning is the observation that a model's performance can vary "
            "dramatically depending on the choice of prompt format, the training examples "
            "given, and the order those examples appear in, without any weight updates."
        ),
    ),
    EvalItem(
        question="What are augmented language models and how do they extend a plain LLM?",
        routing="vectorstore",
        ground_truth=(
            "Augmented language models extend an LLM with external tools such as "
            "retrieval systems, code interpreters, or APIs, giving it access to current "
            "information and precise computation beyond what the model alone can do."
        ),
    ),
    # --- adversarial attacks (2023-10-25-adv-attack-llm) ---
    EvalItem(
        question="What is token manipulation as an adversarial attack on LLMs?",
        routing="vectorstore",
        ground_truth=(
            "Token manipulation is a black-box attack that alters a small fraction of "
            "tokens in the input text, e.g. via synonym replacement, random insertion, or "
            "deletion, using methods like TextFooler or BERT-Attack to preserve meaning "
            "while fooling the model."
        ),
    ),
    EvalItem(
        question="What is Greedy Coordinate Gradient (GCG) and what type of attack is it?",
        routing="vectorstore",
        ground_truth=(
            "GCG is a white-box, gradient-based attack that greedily searches for "
            "single-token substitutions using model gradients to find a suffix that "
            "triggers an unsafe or unintended model response."
        ),
    ),
    EvalItem(
        question="What are the two failure modes exploited by jailbreak prompting?",
        routing="vectorstore",
        ground_truth=(
            "Jailbreak prompting exploits competing objectives (such as prefix injection "
            "or refusal suppression) and mismatched generalization (such as encoding "
            "obfuscation or language translation) to bypass a model's safety training."
        ),
    ),
    EvalItem(
        question="What is human red-teaming used for in LLM adversarial testing?",
        routing="vectorstore",
        ground_truth=(
            "Human red-teaming has people craft adversarial examples, sometimes guided by "
            "saliency scores or token substitution suggestions from a tool, to build "
            "high-quality attack datasets such as the BAD dataset or Anthropic's red-team "
            "attempts collection."
        ),
    ),
    EvalItem(
        question="What is model red-teaming?",
        routing="vectorstore",
        ground_truth=(
            "Model red-teaming trains a separate adversarial model to generate attack "
            "prompts against a target LLM, using reward signals from a harmfulness "
            "classifier, via approaches like zero-shot generation, supervised "
            "fine-tuning, or reinforcement learning."
        ),
    ),
    EvalItem(
        question="What are Universal Adversarial Triggers (UAT)?",
        routing="vectorstore",
        ground_truth=(
            "Universal Adversarial Triggers are input-agnostic sequences of tokens found "
            "via gradient-based search that can be appended to many different inputs and "
            "still reliably trigger a target model behavior."
        ),
    ),
    EvalItem(
        question="What is HotFlip and how does it generate adversarial text?",
        routing="vectorstore",
        ground_truth=(
            "HotFlip is a gradient-based, white-box attack that uses a first-order Taylor "
            "expansion around token/character embeddings to estimate which character-level "
            "substitutions will most increase the model's loss, then applies those flips."
        ),
    ),
    # --- websearch (topics outside the corpus, on purpose) ---
    EvalItem(question="What is today's weather forecast in Paris?", routing="websearch", ground_truth=None),
    EvalItem(question="Who won the most recent Super Bowl?", routing="websearch", ground_truth=None),
    EvalItem(question="What is the current price of Bitcoin?", routing="websearch", ground_truth=None),
    EvalItem(question="What is the latest stable version of Python?", routing="websearch", ground_truth=None),
    EvalItem(question="What is the current population of Japan?", routing="websearch", ground_truth=None),
]

VECTORSTORE_ITEMS = [item for item in DATASET if item.routing == "vectorstore"]
WEBSEARCH_ITEMS = [item for item in DATASET if item.routing == "websearch"]
