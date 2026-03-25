"""Unit tests for pymol.ai_tools — headless, no PyMOL required."""

import json
import os
import sys
import types
import unittest
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Bootstrap: fake pymol package so submodule imports work without _cmd
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

# Ensure claude_agent_sdk is NOT available (force legacy path)
sys.modules["claude_agent_sdk"] = None

# Stub pymol.ai_chat_ui (imported by _run_on_main fallback)
if "pymol.ai_chat_ui" not in sys.modules:
    sys.modules["pymol.ai_chat_ui"] = None

from pymol.ai_tools import (
    TOOL_DEFINITIONS,
    execute_tool,
    _impl_search_pdb,
    _TOOL_HANDLERS,
)


class TestToolDefinitions(unittest.TestCase):
    """Tests for the TOOL_DEFINITIONS constant."""

    def test_has_four_tools(self):
        self.assertEqual(len(TOOL_DEFINITIONS), 4)

    def test_tool_names(self):
        names = {t["name"] for t in TOOL_DEFINITIONS}
        self.assertEqual(
            names,
            {"get_session_state", "execute_command", "capture_viewport", "search_pdb"},
        )

    def test_each_tool_has_input_schema(self):
        for tool_def in TOOL_DEFINITIONS:
            self.assertIn("input_schema", tool_def, f"Missing input_schema on {tool_def['name']}")
            schema = tool_def["input_schema"]
            self.assertEqual(schema["type"], "object")
            self.assertIn("properties", schema)

    def test_each_tool_has_description(self):
        for tool_def in TOOL_DEFINITIONS:
            self.assertIsInstance(tool_def["description"], str)
            self.assertGreater(len(tool_def["description"]), 10)

    def test_search_pdb_requires_query(self):
        search_def = next(t for t in TOOL_DEFINITIONS if t["name"] == "search_pdb")
        self.assertIn("query", search_def["input_schema"]["required"])

    def test_execute_command_requires_command(self):
        exec_def = next(t for t in TOOL_DEFINITIONS if t["name"] == "execute_command")
        self.assertIn("command", exec_def["input_schema"]["required"])

    def test_serializable(self):
        dumped = json.dumps(TOOL_DEFINITIONS)
        reloaded = json.loads(dumped)
        self.assertEqual(reloaded, TOOL_DEFINITIONS)


class TestExecuteTool(unittest.TestCase):
    """Tests for execute_tool() dispatcher."""

    def test_unknown_tool(self):
        result = execute_tool("nonexistent_tool", {}, MagicMock())
        self.assertIn("Unknown tool", result)

    def test_routes_to_get_session_state(self):
        mock_cmd = MagicMock()
        mock_cmd.get_names.return_value = []
        mock_cmd.get_view.return_value = [0.0] * 18
        mock_cmd.get_viewport.return_value = (800, 600)
        result = execute_tool("get_session_state", {}, mock_cmd)
        parsed = json.loads(result)
        self.assertIn("objects", parsed)

    def test_routes_to_execute_command(self):
        mock_cmd = MagicMock()
        mock_cmd._get_feedback.return_value = []
        result = execute_tool("execute_command", {"command": "zoom"}, mock_cmd)
        self.assertIn("OK", result)

    def test_routes_to_search_pdb(self):
        with patch("pymol.ai_tools._impl_search_pdb", return_value=[{"pdb_id": "1UBQ"}]):
            result = execute_tool("search_pdb", {"query": "ubiquitin"}, MagicMock())
            parsed = json.loads(result)
            self.assertIsInstance(parsed, list)
            self.assertEqual(parsed[0]["pdb_id"], "1UBQ")

    def test_empty_query_search_pdb(self):
        result = execute_tool("search_pdb", {"query": ""}, MagicMock())
        parsed = json.loads(result)
        self.assertIn("error", parsed)

    def test_handler_exception_returns_error_string(self):
        with patch.dict(_TOOL_HANDLERS, {"get_session_state": MagicMock(side_effect=RuntimeError("boom"))}):
            result = execute_tool("get_session_state", {}, MagicMock())
            self.assertIn("Error executing tool", result)
            self.assertIn("boom", result)


class TestImplSearchPdb(unittest.TestCase):
    """Tests for _impl_search_pdb()."""

    def test_calls_search_pdb_from_ai_pdb_search(self):
        with patch("pymol.ai_pdb_search.search_pdb", return_value=[]) as mock_search:
            result = _impl_search_pdb("kinase", 5)
            mock_search.assert_called_once_with("kinase", max_results=5)
            self.assertEqual(result, [])

    def test_clamps_max_results(self):
        with patch("pymol.ai_pdb_search.search_pdb", return_value=[]) as mock_search:
            _impl_search_pdb("test", 100)
            mock_search.assert_called_once_with("test", max_results=25)

        with patch("pymol.ai_pdb_search.search_pdb", return_value=[]) as mock_search:
            _impl_search_pdb("test", -5)
            mock_search.assert_called_once_with("test", max_results=1)


if __name__ == "__main__":
    unittest.main()
