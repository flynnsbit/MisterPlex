#!/usr/bin/env python3
"""Read native Quartus STA summary tables, including labelled timing models."""
from __future__ import annotations

from dataclasses import dataclass, field
import math
from pathlib import Path
import re

NUMERIC = r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"
SLACK_SECTIONS = {"Setup", "Hold", "Recovery", "Removal", "Minimum Pulse Width"}
SECTION_PATTERN = r"(Fmax|Setup|Hold|Recovery|Removal|Minimum Pulse Width)"
MODEL_PATTERN = r"(?:Slow|Fast)\s+\d+(?:\.\d+)?mV\s+[+-]?\d+(?:\.\d+)?C\s+Model"


@dataclass(frozen=True)
class SlackRow:
    section: str
    clock: str
    slack: float
    tns: float
    model: str = ""


@dataclass(frozen=True)
class FmaxRow:
    clock: str
    fmax: str
    restricted: str
    model: str = ""


@dataclass
class StaReport:
    slack_rows: list[SlackRow] = field(default_factory=list)
    fmax_rows: list[FmaxRow] = field(default_factory=list)
    sections: dict[str, set[str]] = field(default_factory=dict)


def cells(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip(";").split(";")]


def number(text: str) -> float:
    if not re.fullmatch(NUMERIC, text.strip()):
        raise ValueError(f"malformed timing number: {text!r}")
    value = float(text)
    if not math.isfinite(value):
        raise ValueError(f"non-finite timing number: {text!r}")
    return value


def summary_title(title: str) -> tuple[str, str] | None:
    match = re.fullmatch(rf"(?:(.+?)\s+)?{SECTION_PATTERN}\s+Summary", title.strip())
    if not match:
        return None
    model, section = match.groups()
    model = re.sub(r"\s+", " ", model or "")
    if model and not re.fullmatch(MODEL_PATTERN, model):
        raise ValueError(f"malformed timing model heading: {title!r}")
    return model, section


def parse_sta_report(path: Path) -> StaReport:
    report = StaReport()
    declared, seen = set(), set()
    active = None
    columns = None
    count = 0
    bordered = False

    def finish(closed=False, empty=False):
        nonlocal active, columns, count, bordered
        if active is not None:
            if not empty and (columns is None or count == 0):
                raise ValueError(f"missing timing table header/data: {active}")
            if bordered and count and not closed:
                raise ValueError(f"unterminated timing table: {active}")
        active, columns, count, bordered = None, None, 0, False

    for line in path.read_text().splitlines():
        text = line.strip()
        toc = re.match(r"^\d+\.\s+(.+)$", text)
        if toc:
            title = summary_title(toc.group(1))
            if title:
                declared.add(title)
            continue
        panel = re.fullmatch(r";\s*([^;]+?)\s*;", text)
        heading = summary_title(panel.group(1)) if panel else None
        if heading:
            finish()
            if heading in seen:
                raise ValueError(f"duplicate timing summary table: {heading}")
            seen.add(heading)
            active = heading
            report.sections.setdefault(heading[0], set()).add(heading[1])
            continue
        if active is None or not text:
            continue
        if set(text) <= {"+", "-"}:
            if columns is not None and count:
                finish(closed=True)
            else:
                bordered = True
            continue
        if text == "Nothing to report.":
            if count:
                raise ValueError(f"contradictory empty timing table: {active}")
            finish(closed=True, empty=True)
            continue
        if not text.startswith(";"):
            finish()
            continue
        values = cells(text)
        if not any(values):
            finish()
            continue
        model, section = active
        required = ("Fmax", "Restricted Fmax", "Clock Name") if section == "Fmax" else ("Clock", "Slack", "End Point TNS")
        if columns is None:
            if not all(name in values for name in required):
                raise ValueError(f"malformed timing column header: {active}")
            columns = {name: values.index(name) for name in required}
            continue
        if len(values) <= max(columns.values()) or not all(values[index] for index in columns.values()):
            raise ValueError(f"malformed timing data row: {active}")
        if all(name in values for name in required):
            raise ValueError(f"duplicate timing column header: {active}")
        if section == "Fmax":
            report.fmax_rows.append(FmaxRow(values[columns["Clock Name"]], values[columns["Fmax"]],
                                            values[columns["Restricted Fmax"]], model))
        else:
            report.slack_rows.append(SlackRow(section, values[columns["Clock"]],
                                              number(values[columns["Slack"]]),
                                              number(values[columns["End Point TNS"]]), model))
        count += 1
    finish()
    if declared - seen:
        raise ValueError(f"STA contents lists missing timing tables: {sorted(declared - seen)}")
    for model, sections in report.sections.items():
        if model and SLACK_SECTIONS - sections:
            raise ValueError(f"incomplete native timing model {model}: missing {sorted(SLACK_SECTIONS - sections)}")
    return report
