from __future__ import annotations

import csv
import io
from typing import Iterable


def dump_csv(rows: Iterable[dict], fieldnames: list[str]) -> str:
    buffer = io.StringIO()
    writer = csv.DictWriter(buffer, fieldnames=fieldnames)
    writer.writeheader()
    for row in rows:
        writer.writerow(row)
    return buffer.getvalue()


def load_csv(text: str) -> list[dict[str, str]]:
    buffer = io.StringIO(text)
    return list(csv.DictReader(buffer))
