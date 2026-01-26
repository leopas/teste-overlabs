from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any, Protocol

import httpx

from .config import settings


class LLMProvider(Protocol):
    async def generate(self, question: str, evidence: list[str]) -> dict[str, Any]:
        """
        Retorna um dict com:
        - answer: str
        - confidence_hint: float (0..1)
        - used_sources_indices: list[int]
        """


_JSON_OBJ_RE = re.compile(r"\{[\s\S]*\}", re.MULTILINE)


def _safe_parse_json(text: str) -> dict[str, Any]:
    # tenta extrair o primeiro objeto JSON
    m = _JSON_OBJ_RE.search(text.strip())
    if not m:
        raise ValueError("LLM não retornou JSON")
    return json.loads(m.group(0))


@dataclass(frozen=True)
class StubLLM(LLMProvider):
    async def generate(self, question: str, evidence: list[str]) -> dict[str, Any]:
        return {
            "answer": "",
            "confidence_hint": 0.1,
            "used_sources_indices": [],
            "refusal": True,
        }


class OpenAILLM(LLMProvider):
    def __init__(self, api_key: str) -> None:
        self._api_key = api_key
        self._client = httpx.AsyncClient(timeout=15.0)

    async def generate(self, question: str, evidence: list[str]) -> dict[str, Any]:
        system = (
            "Você é um assistente de QA estrito. Responda SOMENTE com base nos TRECHOS fornecidos.\n"
            "Se não houver evidência suficiente, recuse.\n"
            "NUNCA invente.\n"
            "Se a pergunta especificar um escopo (ex.: nacional vs internacional), responda APENAS sobre esse escopo.\n"
            "Seja objetivo: responda em 1 frase curta, sem contexto extra (sem datas/títulos), a menos que seja pedido.\n"
            "Retorne JSON estrito com as chaves: answer, confidence_hint (0..1), used_sources_indices.\n"
            "used_sources_indices deve conter índices (0-based) dos trechos usados.\n"
        )
        user = (
            "PERGUNTA:\n"
            f"{question}\n\n"
            "TRECHOS (com índice):\n"
            + "\n\n".join([f"[{i}] {t}" for i, t in enumerate(evidence)])
        )

        payload = {
            "model": settings.openai_model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "temperature": 0.0,
        }
        headers = {"Authorization": f"Bearer {self._api_key}"}
        r = await self._client.post("https://api.openai.com/v1/chat/completions", json=payload, headers=headers)
        r.raise_for_status()
        data = r.json()
        content = data["choices"][0]["message"]["content"]
        parsed = _safe_parse_json(content)

        # Sanitização
        parsed.setdefault("answer", "")
        parsed.setdefault("confidence_hint", 0.0)
        parsed.setdefault("used_sources_indices", [])
        return parsed


def get_llm_provider() -> LLMProvider:
    if settings.openai_api_key:
        return OpenAILLM(settings.openai_api_key)
    return StubLLM()


def get_current_llm_model_name() -> str:
    return settings.openai_model if settings.openai_api_key else "stub"

