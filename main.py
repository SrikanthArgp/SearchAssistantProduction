from dotenv import load_dotenv

load_dotenv()
from pprint import pprint

from langgraph.checkpoint.memory import MemorySaver

from graph import create_app
from observability.langfuse_client import get_langfuse_handler

app = create_app(MemorySaver())

# question1 = "What are the types of agent memory?"
# inputs = {"question": question1}

# question = "What are the types of prompt engineering?"
# inputs = {"question": question}

question = "What is Harness engineering, why is it gaining traction?"
inputs = {"question": question}

callbacks = []
langfuse_handler = get_langfuse_handler()
if langfuse_handler is not None:
    callbacks.append(langfuse_handler)

config = {"configurable": {"thread_id": "2"}, "callbacks": callbacks}

try:
    value = None
    for output in app.stream(inputs, config=config): # type: ignore
        for key, value in output.items():
            pprint(f"Finished running: {key}:")
    if value is not None:
        pprint(value["generation"])
except Exception as exc:
    print(f"Something went wrong while running the agent: {exc}")
