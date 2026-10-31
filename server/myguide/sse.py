"""Watch a Responses SSE stream on its way through for its terminal event (spec 6, Streaming).

Terminal events are `response.completed`, `response.incomplete` and `response.failed`. The usage is taken from
the `response` object of any of them (the tokens were spent either way); `completed` is true only for
`response.completed`, which alone keeps the unit.

The bytes themselves are passed on unchanged by the proxy; this only reads them. Event framing follows the
SSE spec: lines end in LF, CRLF or a lone CR; `field: value` lines (one space after the colon is dropped);
lines starting with `:` are comments; data lines are joined with LF; a blank line dispatches the event; an
event not closed by a blank line before the stream ends is dropped.

Nothing read here is stored or logged: only `completed` and the `usage` counts leave this object.
"""
from __future__ import annotations

import json

from .pricing import Usage, usage_from_json

_COMPLETED = "response.completed"
_TERMINAL = frozenset({_COMPLETED, "response.incomplete", "response.failed"})


class CompletedWatcher:
    def __init__(self) -> None:
        self.completed = False
        self.usage = Usage()
        self._buffer = b""
        self._event: str | None = None
        self._data: list[bytes] = []

    def feed(self, chunk: bytes) -> None:
        """Read the next piece of the stream; pieces may split lines (and CRLF pairs) anywhere."""
        if not chunk:
            return
        buffer = self._buffer + chunk
        start = 0
        n = len(buffer)
        while True:
            lf = buffer.find(b"\n", start)
            cr = buffer.find(b"\r", start)
            if lf == -1 and cr == -1:
                break
            if cr != -1 and (lf == -1 or cr < lf):
                if cr + 1 == n:
                    break  # a CR at the end: the LF of a CRLF may open the next chunk
                end, next_start = cr, cr + 2 if buffer[cr + 1:cr + 2] == b"\n" else cr + 1
            else:
                end, next_start = lf, lf + 1
            self._line(buffer[start:end])
            start = next_start
        self._buffer = buffer[start:]

    def close(self) -> None:
        """The stream ended: a CR held back at the end of the last piece is a line end after all.
        An event still open (no blank line yet) is dropped, as the SSE spec says."""
        if self._buffer.endswith(b"\r"):
            self.feed(b"\n")
        self._buffer = b""
        self._event, self._data = None, []

    def _line(self, line: bytes) -> None:
        if not line:
            self._dispatch()
            return
        if line.startswith(b":"):
            return
        name, sep, value = line.partition(b":")
        if sep and value.startswith(b" "):
            value = value[1:]
        if name == b"event":
            self._event = value.decode("utf-8", "replace")
        elif name == b"data" and (self._event is None or self._event in _TERMINAL):
            self._data.append(value)  # data of other named events is never parsed, so not kept

    def _dispatch(self) -> None:
        event, data = self._event, self._data
        self._event, self._data = None, []
        if not data:
            return
        if event is not None and event not in _TERMINAL:
            return
        try:
            obj = json.loads(b"\n".join(data))
        except (ValueError, RecursionError):  # JSONDecodeError and UnicodeDecodeError are ValueErrors
            return
        if not isinstance(obj, dict):
            return
        name = event if event is not None else obj.get("type")
        response = obj.get("response")
        if name not in _TERMINAL or not isinstance(response, dict):
            return
        self.completed = name == _COMPLETED
        self.usage = usage_from_json(response)
