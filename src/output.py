"""
output.py — writes the pipeline run summary to a JSON file.
"""

import json
import os
from datetime import datetime


def _reconciliation(steps: list) -> list:
    for step in steps:
        if step.get("step") == "compare_layers":
            return [
                {
                    "table":       c["check"],
                    "build_count": c["left"],
                    "star_count":  c["right"],
                    "delta":       c["delta"],
                    "status":      c["status"],
                }
                for c in step.get("comparisons", [])
            ]
    return []


def save(steps: list, outputs_dir: str, script_name: str) -> str:
    os.makedirs(outputs_dir, exist_ok=True)
    run_ts   = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_file = os.path.join(outputs_dir, f"{script_name}_{run_ts}.json")

    payload = {
        "run_at":                datetime.now().isoformat(),
        "layer_reconciliation":  _reconciliation(steps),
        "steps":                 steps,
    }

    with open(out_file, "w") as f:
        json.dump(payload, f, indent=2, default=str, ensure_ascii=False)

    print(f"[OUTPUT] Saved → {out_file}")
    return out_file
