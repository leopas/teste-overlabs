from __future__ import annotations

import re
from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator


_CONTROL_CHARS_RE = re.compile(r"[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]")


class AskRequest(BaseModel):
    question: str = Field(..., min_length=3, max_length=2000)

    @field_validator("question")
    @classmethod
    def no_control_chars(cls, v: str) -> str:
        if _CONTROL_CHARS_RE.search(v):
            raise ValueError("question contém caracteres de controle")
        return v


class SourceItem(BaseModel):
    document: str
    excerpt: str


class AskResponse(BaseModel):
    answer: str
    confidence: float = Field(..., ge=0.0, le=1.0)
    sources: list[SourceItem]


class RefusalReason(BaseModel):
    kind: Literal[
        "input_invalid",
        "guardrail_injection",
        "guardrail_sensitive",
        "guardrail_firewall",
        "rate_limited",
        "cache_error",
        "qdrant_unavailable",
        "no_evidence",
        "conflict_unresolved",
        "quality_threshold",
        "quality_crosscheck_failed",
        "quality_post_validation_failed",
        "llm_error",
    ]
    details: dict[str, Any] = Field(default_factory=dict)

