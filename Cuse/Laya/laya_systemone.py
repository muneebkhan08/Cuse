#!/usr/bin/env python3
"""Local click-decision server for Cuse.

Speaks the same POST /v1/systemone body Cuse already sends, and answers it
with the Laya checkpoint installed under Application Support/Cuse/laya.

That cache contains laya-multilingual (mmBERT-base, 322M). It is the checkpoint
this server uses: it reads on-screen labels in 100+ languages, and max_len=8192
keeps a long control list that the English checkpoint would cut off at 512
tokens. The typed-decisions checkpoint is a fine-tune of four unrelated
workflows and is not in this cache.
"""

import json
import os
import threading
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Resolve the install before importing Laya so the first hub lookup hits the
# weights already downloaded next to this machine's virtualenv.
LAYA_HOME = os.environ.get(
    "LAYA_HOME",
    os.path.expanduser("~/Library/Application Support/Cuse/laya"),
)
os.environ.setdefault("HF_HOME", os.path.join(LAYA_HOME, "hf"))
os.environ.setdefault("HF_HUB_CACHE", os.path.join(LAYA_HOME, "hf", "hub"))
os.environ.setdefault("HUGGINGFACE_HUB_CACHE", os.path.join(LAYA_HOME, "hf", "hub"))
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")

MODEL_NAME = "multilingual"
# Multilingual's default window is 1024. Screen lists are longer than that;
# 8192 is the checkpoint's documented long-document limit. Short inputs still
# run at their real length.
MAX_LEN = 8192
# Option text shares a 256-token budget. Past ~20 described controls the labels
# are trimmed until they look the same, so keep a short embedding shortlist and
# always retain the explicit "none of these" escape hatch.
SHORTLIST_LIMIT = 24
NONE_KEY = "__none__"
MAX_BODY_BYTES = 2 * 1024 * 1024

HOST = os.environ.get("LAYA_HOST", "127.0.0.1")
PORT = int(os.environ.get("LAYA_PORT", "8765"))

_inference_lock = threading.Lock()
_router = None
_embed = None


def choose_device():
    requested = os.environ.get("LAYA_DEVICE", "").strip()
    if requested:
        return requested
    import torch

    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def load_router():
    """Load only the multilingual checkpoint that is already on disk."""
    global _router, _embed
    from laya import Router
    from laya.shortlist import embed_fn_from_agent

    device = choose_device()
    router = Router(device=device, max_loaded=1)
    router.preload([MODEL_NAME])
    agent = router.load(MODEL_NAME)
    _router = router
    # One embedder for the life of the process. 0.3.20 has no embed cache.
    _embed = embed_fn_from_agent(agent)
    print(
        "cuse-laya loaded model=%s device=%s home=%s" % (MODEL_NAME, device, LAYA_HOME),
        flush=True,
    )
    return router


def shortlist_questions(state, questions):
    """Shrink oversized choice questions. Returns questions and ids kept for `pick`."""
    from laya.shortlist import shortlist_choice

    reduced = {}
    kept_pick_ids = None
    for question_id, question in questions.items():
        if not isinstance(question, dict) or question.get("type") != "choice":
            reduced[question_id] = question
            continue
        criteria = question.get("criteria")
        if not isinstance(criteria, dict) or len(criteria) <= SHORTLIST_LIMIT:
            reduced[question_id] = question
            if question_id == "pick" and isinstance(criteria, dict):
                kept_pick_ids = set(criteria)
            continue

        reserved_none = criteria.get(NONE_KEY)
        pool = {key: value for key, value in criteria.items() if key != NONE_KEY}
        budget = SHORTLIST_LIMIT - (1 if reserved_none is not None else 0)
        if len(pool) <= budget:
            labels = list(pool)
        else:
            labels = shortlist_choice(
                state,
                pool,
                _embed,
                k=budget,
                instructions=question.get("instructions"),
            )
        kept = {label: pool[label] for label in labels if label in pool}
        if reserved_none is not None:
            kept[NONE_KEY] = reserved_none
        updated = dict(question)
        updated["criteria"] = kept
        reduced[question_id] = updated
        if question_id == "pick":
            kept_pick_ids = set(kept)
    return reduced, kept_pick_ids


def align_screen_elements(state, kept_pick_ids):
    """Keep the state list and the choice options describing the same controls."""
    if not kept_pick_ids or not isinstance(state, dict):
        return state
    elements = state.get("screen_elements")
    if not isinstance(elements, list):
        return state
    aligned = dict(state)
    aligned["screen_elements"] = [
        element
        for element in elements
        if isinstance(element, dict) and element.get("id") in kept_pick_ids
    ]
    return aligned


def completion_text(state):
    """Task plus action history, without the on-screen labels.

    With the labels in the same text, this checkpoint reports the task
    complete (about 0.99) before any click. Without them, "nothing yet"
    stays near 0.3 and a finished click crosses the 0.70 stop line.
    """
    if not isinstance(state, dict):
        return state
    task = state.get("task", "")
    history = state.get("already_done", ["nothing yet"])
    if isinstance(history, list):
        history_text = "; ".join(str(item) for item in history) if history else "nothing yet"
    else:
        history_text = str(history)
    return "Task: %s. Actions already taken: %s." % (task, history_text)


def predict(state, questions):
    with _inference_lock:
        return _router.predict(state, questions, model=MODEL_NAME, max_len=MAX_LEN)


def decide(state, questions):
    noul_questions = {}
    other_questions = {}
    for question_id, question in questions.items():
        if isinstance(question, dict) and question.get("type") == "noul":
            noul_questions[question_id] = question
        else:
            other_questions[question_id] = question

    answers = {}
    input_tokens = 0
    output_tokens = 0

    def absorb(result):
        nonlocal input_tokens, output_tokens
        if not isinstance(result, dict):
            return
        answers.update(result.get("answers") or {})
        usage = result.get("usage") or {}
        input_tokens += int(usage.get("input_tokens") or 0)
        output_tokens += int(usage.get("output_tokens") or 0)

    if noul_questions:
        # The measured yes/no question. The longer screen-judging wording
        # stays near 0.9 even when nothing has been clicked.
        rewritten = {}
        for question_id, question in noul_questions.items():
            updated = dict(question)
            if question_id == "done":
                updated["instructions"] = "Has this task been completed?"
            rewritten[question_id] = updated
        absorb(predict(completion_text(state), rewritten))

    if other_questions:
        reduced, kept_pick_ids = shortlist_questions(state, other_questions)
        absorb(predict(align_screen_elements(state, kept_pick_ids), reduced))

    return {
        "model": MODEL_NAME,
        "answers": answers,
        "usage": {"input_tokens": input_tokens, "output_tokens": output_tokens},
    }


class SystemOneHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        # BaseHTTPRequestHandler logs every request line to stderr. Cuse
        # already records the decision; skip the access log so screen text
        # from a verbose client cannot land in the server log by accident.
        return

    def do_GET(self):
        if self.path.split("?", 1)[0] != "/health":
            self._send_json(404, {"detail": "not found"})
            return
        self._send_json(
            200,
            {
                "status": "ok",
                "service": "cuse-laya",
                "model": MODEL_NAME,
                "home": LAYA_HOME,
            },
        )

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/v1/systemone":
            self._send_json(404, {"detail": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send_json(400, {"detail": "Content-Length must be an integer"})
            return
        if length <= 0 or length > MAX_BODY_BYTES:
            self._send_json(413, {"detail": "request body is empty or too large"})
            return
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw)
        except (ValueError, RecursionError):
            self._send_json(400, {"detail": "request body must be valid JSON"})
            return
        if not isinstance(body, dict) or not isinstance(body.get("questions"), dict):
            self._send_json(400, {"detail": "request body must be an object with a questions object"})
            return
        if body.get("state") is None:
            self._send_json(400, {"detail": "state is required"})
            return
        try:
            result = decide(body["state"], body["questions"])
        except ValueError as error:
            self._send_json(422, {"detail": str(error)})
            return
        except Exception:
            traceback.print_exc()
            self._send_json(500, {"detail": "inference failed"})
            return
        self._send_json(200, result)

    def _send_json(self, status, payload):
        data = json.dumps(payload, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    load_router()
    server = ThreadingHTTPServer((HOST, PORT), SystemOneHandler)
    print("cuse-laya listening on http://%s:%s" % (HOST, PORT), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
