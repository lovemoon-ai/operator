"""Prompt library offered in the headset menu; free text also arrives from the host terminal."""
from __future__ import annotations

from pathlib import Path
from typing import Iterable, Sequence

DEFAULT_PROMPTS = (
    "wave with the right hand",
    "walk forward and turn around",
    "do two squats",
    "punch the air with the left and right hand",
    "wipe a table with the right hand",
    "bow politely",
    "jump in place",
    "stretch both arms above the head",
    "kick with the right leg",
    "dance happily",
)


def clean_prompts(prompts: Iterable[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for prompt in prompts:
        text = " ".join(str(prompt).split())
        key = text.lower()
        if text and key not in seen:
            seen.add(key)
            result.append(text)
    return result


def load_prompts(path) -> list[str]:
    """One prompt per line; blank lines and ``#`` comments are ignored."""
    lines = Path(path).expanduser().read_text(encoding="utf-8").splitlines()
    prompts = clean_prompts(line for line in lines if line.strip() and not line.lstrip().startswith("#"))
    if not prompts:
        raise ValueError(f"no prompts in {path}")
    return prompts


class PromptLibrary:
    """Ordered prompts with one selection; Next/Prev wrap around."""

    def __init__(self, prompts: Sequence[str]):
        self._prompts = clean_prompts(prompts)
        if not self._prompts:
            raise ValueError("prompt library must contain at least one prompt")
        self.index = 0

    def __len__(self) -> int:
        return len(self._prompts)

    def __iter__(self):
        return iter(self._prompts)

    @property
    def current(self) -> str:
        return self._prompts[self.index]

    def next(self) -> str:
        self.index = (self.index + 1) % len(self._prompts)
        return self.current

    def prev(self) -> str:
        self.index = (self.index - 1) % len(self._prompts)
        return self.current

    def select(self, text: str) -> str:
        """Add ``text`` if new, select it, and return the stored prompt."""
        cleaned = clean_prompts([text])
        if not cleaned:
            raise ValueError("prompt must not be empty")
        prompt = cleaned[0]
        for index, existing in enumerate(self._prompts):
            if existing.lower() == prompt.lower():
                self.index = index
                return existing
        self._prompts.append(prompt)
        self.index = len(self._prompts) - 1
        return prompt
