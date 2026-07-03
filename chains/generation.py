from langchain_core.output_parsers import StrOutputParser
from langchain_core.prompts import ChatPromptTemplate
from langchain_openai import ChatOpenAI

llm = ChatOpenAI(temperature=0)

# Inlined from the LangChain Hub prompt "rlm/rag-prompt" — hub.pull() made a live
# network call at import time, which broke offline/CI imports.
prompt = ChatPromptTemplate.from_messages(
    [
        (
            "human",
            """You are an assistant for question-answering tasks.
Use the following pieces of retrieved context to answer the question.
If you don't know the answer, say that you don't know. Use three sentences maximum.

Question: {question}
Context: {context}
Answer:""",
        )
    ]
)

generation_chain = prompt | llm | StrOutputParser()
