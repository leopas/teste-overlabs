from __future__ import annotations

import os
import re
from dataclasses import dataclass
from typing import Any

from .llm import LLMProvider
from .retrieval import FastEmbedEmbeddings, OpenAIEmbeddings, excerpt_for_question


class FailOnCallLLM(LLMProvider):
    async def generate(self, question: str, evidence: list[str]) -> dict[str, Any]:
        raise RuntimeError("LLM should not be called")


@dataclass
class SpyLLM(LLMProvider):
    inner: LLMProvider
    calls: int = 0
    last_question: str | None = None
    last_evidence: list[str] | None = None

    async def generate(self, question: str, evidence: list[str]) -> dict[str, Any]:
        self.calls += 1
        self.last_question = question
        self.last_evidence = evidence
        return await self.inner.generate(question=question, evidence=evidence)


class LocalDeterministicLLM(LLMProvider):
    """
    LLM local determinística: extrai uma frase existente nos trechos,
    sem inventar e sem rede.
    """

    async def generate(self, question: str, evidence: list[str]) -> dict[str, Any]:
        if not evidence:
            return {"answer": "", "confidence_hint": 0.1, "used_sources_indices": [], "refusal": True}

        # Escolhe o primeiro trecho (que já vem re-rankeado no pipeline)
        best_idx = 0
        best_text = evidence[best_idx]

        # Extrair frase objetiva a partir do próprio trecho
        candidate = excerpt_for_question(best_text, question, max_chars=240)
        candidate = candidate.strip()
        if not candidate:
            return {"answer": "", "confidence_hint": 0.2, "used_sources_indices": [], "refusal": True}

        # Garantir 1 frase curta (até o primeiro ponto final)
        m = re.split(r"(?<=[.!?])\s+", candidate)
        one_sentence = (m[0] if m else candidate).strip()

        return {
            "answer": one_sentence,
            "confidence_hint": 0.7,
            "used_sources_indices": [best_idx],
        }


def create_embedder_from_env() -> Any:
    """
    Para testes prod-like: cria embedder conforme env (sem depender do singleton settings).
    - Se USE_OPENAI_EMBEDDINGS=1 e OPENAI_API_KEY existir, usa OpenAI.
    - Caso contrário, usa FastEmbed (ONNX).
    """
    use_openai = os.getenv("USE_OPENAI_EMBEDDINGS", "").strip() in ("1", "true", "yes")
    api_key = os.getenv("OPENAI_API_KEY") or ""
    if use_openai and api_key:
        return OpenAIEmbeddings(api_key)
    return FastEmbedEmbeddings()

