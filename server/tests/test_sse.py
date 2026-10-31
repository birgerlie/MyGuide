"""CompletedWatcher: finds the final `response.completed` event in a Responses SSE stream (spec 6, Streaming)."""
from __future__ import annotations

import json

import pytest

from myguide.pricing import Usage
from myguide.sse import CompletedWatcher

USAGE = {"input_tokens": 1000, "input_tokens_details": {"cached_tokens": 200}, "output_tokens": 500}


def completed_event(usage=USAGE, *, event_line=True, newline="\n") -> bytes:
    data = json.dumps({"type": "response.completed", "response": {"id": "resp_1", "usage": usage}})
    lines = (["event: response.completed"] if event_line else []) + [f"data: {data}", "", ""]
    return newline.join(lines).encode()


def delta(text: str, newline="\n") -> bytes:
    data = json.dumps({"type": "response.output_text.delta", "delta": text})
    return newline.join(["event: response.output_text.delta", f"data: {data}", "", ""]).encode()


def feed_all(*chunks: bytes) -> CompletedWatcher:
    w = CompletedWatcher()
    for c in chunks:
        w.feed(c)
    w.close()
    return w


def test_completed_split_across_three_chunks_crlf():
    stream = delta("Hei", "\r\n") + completed_event(newline="\r\n")
    a, b = len(stream) // 3, 2 * len(stream) // 3
    w = feed_all(stream[:a], stream[a:b], stream[b:])
    assert w.completed
    assert w.usage == Usage(1000, 200, 500)


def test_completed_split_between_cr_and_lf():
    stream = completed_event(newline="\r\n")
    cut = stream.index(b"\r\n") + 1  # the chunk ends on the CR, the LF opens the next chunk
    w = feed_all(stream[:cut], stream[cut:])
    assert w.completed
    assert w.usage == Usage(1000, 200, 500)


@pytest.mark.parametrize("size", [1, 2, 7])
def test_completed_fed_in_tiny_chunks(size):
    stream = delta("a") + completed_event()
    w = feed_all(*(stream[i:i + size] for i in range(0, len(stream), size)))
    assert w.completed
    assert w.usage == Usage(1000, 200, 500)


def test_completed_with_lone_cr_line_ends():
    w = feed_all(completed_event(newline="\r"))
    assert w.completed
    assert w.usage == Usage(1000, 200, 500)


def test_completed_identified_by_data_type_without_event_line():
    w = feed_all(completed_event(event_line=False))
    assert w.completed
    assert w.usage == Usage(1000, 200, 500)


def test_data_without_space_after_colon_and_comment_lines():
    data = json.dumps({"type": "response.completed", "response": {"usage": USAGE}})
    w = feed_all(f": keep-alive\nevent:response.completed\ndata:{data}\n\n".encode())
    assert w.completed
    assert w.usage == Usage(1000, 200, 500)


def test_deltas_only_not_completed():
    w = feed_all(delta("Hei "), delta("på "), delta("deg"))
    assert not w.completed
    assert w.usage == Usage()


def test_done_alone_not_completed():
    w = feed_all(b"data: [DONE]\n\n")
    assert not w.completed
    assert w.usage == Usage()


def test_garbage_json_in_completed_not_completed():
    w = feed_all(b"event: response.completed\ndata: {not json\n\n")
    assert not w.completed
    assert w.usage == Usage()


def test_completed_data_not_an_object_not_completed():
    w = feed_all(b"event: response.completed\ndata: [1,2]\n\n")
    assert not w.completed


def test_completed_without_response_object_not_completed():
    w = feed_all(b'event: response.completed\ndata: {"type":"response.completed"}\n\n')
    assert not w.completed


def test_completed_event_without_final_blank_line_is_not_dispatched():
    # SSE: an event is dispatched on its blank line; a stream that ends before it lost the event.
    w = feed_all(completed_event()[:-2])
    assert not w.completed


@pytest.mark.parametrize("name", ["response.failed", "response.incomplete"])
def test_failed_and_incomplete_are_terminal_with_usage_but_not_completed(name):
    # The tokens of a failed or cut-off story were spent: usage 1000 in / 200 cached / 500 out is counted,
    # but only response.completed keeps the unit.
    data = json.dumps({"type": name, "response": {"usage": USAGE}})
    w = feed_all(delta("a") + f"event: {name}\ndata: {data}\n\n".encode())
    assert not w.completed
    assert w.usage == Usage(1000, 200, 500)


@pytest.mark.parametrize("name", ["response.failed", "response.incomplete"])
def test_failed_and_incomplete_identified_by_data_type_without_event_line(name):
    data = json.dumps({"type": name, "response": {"usage": USAGE}})
    w = feed_all(f"data: {data}\n\n".encode())
    assert not w.completed
    assert w.usage == Usage(1000, 200, 500)


def test_failed_without_response_object_counts_nothing():
    w = feed_all(b'event: response.failed\ndata: {"type":"response.failed"}\n\n')
    assert not w.completed
    assert w.usage == Usage()


def test_error_event_is_not_terminal_and_counts_nothing():
    data = json.dumps({"type": "error", "response": {"usage": USAGE}})
    w = feed_all(f"event: error\ndata: {data}\n\n".encode())
    assert not w.completed
    assert w.usage == Usage()


def test_event_name_wins_over_data_type():
    # Named response.failed: terminal (usage counted) but not completed, whatever the data's type says.
    data = json.dumps({"type": "response.completed", "response": {"usage": USAGE}})
    w = feed_all(f"event: response.failed\ndata: {data}\n\n".encode())
    assert not w.completed
    assert w.usage == Usage(1000, 200, 500)


def test_multi_line_data_joined_with_newline():
    # JSON may legally be split over two data lines; they are joined with "\n" before parsing.
    w = feed_all(b'event: response.completed\ndata: {"type":"response.completed",\ndata: "response":{"usage":'
                 + json.dumps(USAGE).encode() + b"}}\n\n")
    assert w.completed
    assert w.usage == Usage(1000, 200, 500)


def test_completed_without_usage_counts_zero_usage():
    w = feed_all(b'event: response.completed\ndata: {"type":"response.completed","response":{}}\n\n')
    assert w.completed
    assert w.usage == Usage()


def test_utf8_split_inside_a_character():
    raw = json.dumps({"type": "response.output_text.delta", "delta": "på"}, ensure_ascii=False)
    stream = f"event: response.output_text.delta\ndata: {raw}\n\n".encode() + completed_event()
    cut = stream.index("å".encode()) + 1  # between the two bytes of å
    w = feed_all(stream[:cut], stream[cut:])
    assert w.completed


def test_trailing_cr_waits_for_close_or_next_chunk():
    w = CompletedWatcher()
    w.feed(completed_event(newline="\r"))
    assert not w.completed  # the last CR may still be the first half of a CRLF
    w.close()
    assert w.completed


def test_close_does_not_dispatch_an_open_event():
    w = CompletedWatcher()
    w.feed(completed_event()[:-1])  # data line ended, blank line missing
    w.close()
    assert not w.completed


def test_empty_chunks_are_harmless():
    w = feed_all(b"", completed_event(), b"")
    assert w.completed
