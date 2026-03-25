"""Unit tests for pymol.ai_chat — headless, no PyMOL required."""

import json
import os
import sys
import types
import unittest
from unittest.mock import MagicMock, patch, call

# ---------------------------------------------------------------------------
# Bootstrap: prevent the real pymol package from loading (it needs _cmd).
# We insert a fake pymol package into sys.modules with __path__ so that
# submodule imports resolve to the actual .py files on disk.
# ---------------------------------------------------------------------------

_MODULES_DIR = os.path.join(
    os.path.dirname(__file__), os.pardir, os.pardir, "modules"
)
_MODULES_DIR = os.path.normpath(_MODULES_DIR)

if "pymol" not in sys.modules or not hasattr(sys.modules["pymol"], "__path__"):
    _pymol_stub = types.ModuleType("pymol")
    _pymol_stub.__path__ = [os.path.join(_MODULES_DIR, "pymol")]
    _pymol_stub.__package__ = "pymol"
    sys.modules["pymol"] = _pymol_stub

# Stub pymol.ai_system_prompt (used by ai_chat at import time)
_sp = types.ModuleType("pymol.ai_system_prompt")
_sp.SYSTEM_PROMPT = "You are a helpful assistant."
sys.modules["pymol.ai_system_prompt"] = _sp

# Ensure claude_agent_sdk is unavailable (force legacy code path)
sys.modules.setdefault("claude_agent_sdk", None)

# pymol.ai_tools will be imported naturally from the real file since
# pymol.__path__ points to the modules/pymol directory.

from pymol.ai_chat import (
    _parse_structured_response,
    _execute_script,
    _build_api_messages,
    RESPONSE_SCHEMA,
)
import pymol.ai_chat as ai_chat_mod


class TestParseStructuredResponse(unittest.TestCase):
    """Tests for _parse_structured_response()."""

    def test_valid_json_with_response(self):
        payload = {"response": "Hello!", "script": "fetch 1ubq", "questions": []}
        result = _parse_structured_response(json.dumps(payload))
        self.assertEqual(result["response"], "Hello!")
        self.assertEqual(result["script"], "fetch 1ubq")

    def test_valid_json_missing_response_key(self):
        """JSON without 'response' should fall through to fallback."""
        result = _parse_structured_response('{"foo": "bar"}')
        self.assertIn("response", result)
        self.assertIn("{", result["response"])

    def test_malformed_json(self):
        result = _parse_structured_response("{bad json!!!")
        self.assertEqual(result["response"], "{bad json!!!")
        self.assertEqual(result["script"], "")
        self.assertEqual(result["questions"], [])

    def test_plain_text_fallback(self):
        result = _parse_structured_response("Just some plain text.")
        self.assertEqual(result["response"], "Just some plain text.")
        self.assertEqual(result["script"], "")

    def test_json_inside_code_block(self):
        text = 'Some preamble\n```json\n{"response": "inside block"}\n```\ntrailing'
        result = _parse_structured_response(text)
        self.assertEqual(result["response"], "inside block")

    def test_json_embedded_in_text(self):
        text = 'Here is the answer: {"response": "embedded", "script": ""} done.'
        result = _parse_structured_response(text)
        self.assertEqual(result["response"], "embedded")

    def test_empty_string(self):
        result = _parse_structured_response("")
        self.assertEqual(result["response"], "")
        self.assertEqual(result["script"], "")

    def test_whitespace_only(self):
        result = _parse_structured_response("   \n  ")
        self.assertEqual(result["response"], "")


class TestExecuteScript(unittest.TestCase):
    """Tests for _execute_script()."""

    def test_executes_lines_via_cmd_do(self):
        mock_cmd = MagicMock()
        old_cmd = ai_chat_mod._cmd
        ai_chat_mod._cmd = mock_cmd
        try:
            _execute_script("fetch 1ubq\nshow cartoon\ncolor green, ss h")
            calls = mock_cmd.do.call_args_list
            self.assertEqual(len(calls), 3)
            self.assertEqual(calls[0], call("fetch 1ubq", 0, 1))
            self.assertEqual(calls[1], call("show cartoon", 0, 1))
            self.assertEqual(calls[2], call("color green, ss h", 0, 1))
        finally:
            ai_chat_mod._cmd = old_cmd

    def test_skips_blank_lines_and_comments(self):
        mock_cmd = MagicMock()
        old_cmd = ai_chat_mod._cmd
        ai_chat_mod._cmd = mock_cmd
        try:
            _execute_script("# comment\n\n  \nfetch 1ubq\n# another comment")
            self.assertEqual(mock_cmd.do.call_count, 1)
            self.assertEqual(mock_cmd.do.call_args, call("fetch 1ubq", 0, 1))
        finally:
            ai_chat_mod._cmd = old_cmd

    def test_none_script(self):
        mock_cmd = MagicMock()
        old_cmd = ai_chat_mod._cmd
        ai_chat_mod._cmd = mock_cmd
        try:
            _execute_script(None)
            mock_cmd.do.assert_not_called()
        finally:
            ai_chat_mod._cmd = old_cmd

    def test_empty_script(self):
        mock_cmd = MagicMock()
        old_cmd = ai_chat_mod._cmd
        ai_chat_mod._cmd = mock_cmd
        try:
            _execute_script("")
            mock_cmd.do.assert_not_called()
        finally:
            ai_chat_mod._cmd = old_cmd

    def test_cmd_do_exception_is_swallowed(self):
        mock_cmd = MagicMock()
        mock_cmd.do.side_effect = RuntimeError("boom")
        old_cmd = ai_chat_mod._cmd
        ai_chat_mod._cmd = mock_cmd
        try:
            _execute_script("bad_command")
        finally:
            ai_chat_mod._cmd = old_cmd


class TestBuildApiMessages(unittest.TestCase):
    """Tests for _build_api_messages()."""

    def setUp(self):
        self._saved = ai_chat_mod._messages[:]

    def tearDown(self):
        ai_chat_mod._messages[:] = self._saved

    def test_strips_tool_use_blocks(self):
        ai_chat_mod._messages[:] = [
            {"role": "user", "content": "hello"},
            {
                "role": "assistant",
                "content": [
                    {"type": "text", "text": "I will use a tool."},
                    {"type": "tool_use", "id": "t1", "name": "foo", "input": {}},
                ],
            },
            {
                "role": "user",
                "content": [
                    {"type": "tool_result", "tool_use_id": "t1", "content": "ok"},
                ],
            },
            {"role": "user", "content": "thanks"},
        ]
        msgs = _build_api_messages()
        for m in msgs:
            self.assertNotIn("tool_use", str(m))
            self.assertNotIn("tool_result", str(m))

    def test_merges_same_role_messages(self):
        ai_chat_mod._messages[:] = [
            {"role": "user", "content": "first"},
            {"role": "user", "content": "second"},
        ]
        msgs = _build_api_messages()
        self.assertEqual(len(msgs), 1)
        self.assertEqual(msgs[0]["role"], "user")
        self.assertIn("first", msgs[0]["content"])
        self.assertIn("second", msgs[0]["content"])

    def test_simple_conversation(self):
        ai_chat_mod._messages[:] = [
            {"role": "user", "content": "hi"},
            {"role": "assistant", "content": [{"type": "text", "text": "hello"}]},
            {"role": "user", "content": "bye"},
        ]
        msgs = _build_api_messages()
        self.assertEqual(len(msgs), 3)
        self.assertEqual(msgs[0]["role"], "user")
        self.assertEqual(msgs[1]["role"], "assistant")
        self.assertEqual(msgs[2]["role"], "user")

    def test_empty_messages(self):
        ai_chat_mod._messages[:] = []
        msgs = _build_api_messages()
        self.assertEqual(msgs, [])


class TestResponseSchema(unittest.TestCase):
    """Tests for the RESPONSE_SCHEMA constant."""

    def test_is_valid_json_schema_structure(self):
        self.assertIsInstance(RESPONSE_SCHEMA, dict)
        self.assertEqual(RESPONSE_SCHEMA["type"], "object")
        self.assertIn("properties", RESPONSE_SCHEMA)
        self.assertIn("response", RESPONSE_SCHEMA["properties"])
        self.assertIn("required", RESPONSE_SCHEMA)
        self.assertIn("response", RESPONSE_SCHEMA["required"])

    def test_has_expected_properties(self):
        props = RESPONSE_SCHEMA["properties"]
        self.assertIn("response", props)
        self.assertIn("script", props)
        self.assertIn("questions", props)

    def test_questions_schema(self):
        q_schema = RESPONSE_SCHEMA["properties"]["questions"]
        self.assertEqual(q_schema["type"], "array")
        item = q_schema["items"]
        self.assertIn("text", item["properties"])
        self.assertIn("options", item["properties"])
        self.assertIn("type", item["properties"])

    def test_serializes_to_json(self):
        dumped = json.dumps(RESPONSE_SCHEMA)
        reloaded = json.loads(dumped)
        self.assertEqual(reloaded, RESPONSE_SCHEMA)


if __name__ == "__main__":
    unittest.main()
