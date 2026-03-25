"""Unit tests for pymol.ai_pdb_search — headless, no PyMOL required."""

import json
import os
import sys
import types
import unittest
from unittest.mock import patch, MagicMock

# ---------------------------------------------------------------------------
# Bootstrap
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

from pymol.ai_pdb_search import search_pdb, _fetch_all_metadata, _search_ids


def _make_urlopen_response(body_dict):
    """Create a mock context manager for urllib.request.urlopen."""
    resp_bytes = json.dumps(body_dict).encode("utf-8")
    mock_resp = MagicMock()
    mock_resp.read.return_value = resp_bytes
    mock_resp.__enter__ = MagicMock(return_value=mock_resp)
    mock_resp.__exit__ = MagicMock(return_value=False)
    return mock_resp


class TestSearchPdb(unittest.TestCase):
    """Tests for search_pdb() with mocked HTTP responses."""

    @patch("pymol.ai_pdb_search._fetch_all_metadata")
    @patch("pymol.ai_pdb_search._search_ids")
    def test_returns_metadata_for_found_ids(self, mock_ids, mock_meta):
        mock_ids.return_value = ["1UBQ", "4HHB"]
        mock_meta.return_value = [
            {"pdb_id": "1UBQ", "title": "UBIQUITIN", "organism": "Homo sapiens", "resolution": 1.8},
            {"pdb_id": "4HHB", "title": "HEMOGLOBIN", "organism": "Homo sapiens", "resolution": 1.74},
        ]
        results = search_pdb("human protein", max_results=5)
        self.assertEqual(len(results), 2)
        self.assertEqual(results[0]["pdb_id"], "1UBQ")
        mock_ids.assert_called_once_with("human protein", 5)
        mock_meta.assert_called_once_with(["1UBQ", "4HHB"])

    @patch("pymol.ai_pdb_search._search_ids")
    def test_empty_results(self, mock_ids):
        mock_ids.return_value = []
        results = search_pdb("xyznonexistent", max_results=5)
        self.assertEqual(results, [])

    def test_max_results_clamped(self):
        with patch("pymol.ai_pdb_search._search_ids", return_value=[]) as mock_ids:
            search_pdb("test", max_results=100)
            mock_ids.assert_called_once_with("test", 25)

        with patch("pymol.ai_pdb_search._search_ids", return_value=[]) as mock_ids:
            search_pdb("test", max_results=-3)
            mock_ids.assert_called_once_with("test", 1)

    @patch("pymol.ai_pdb_search._search_ids")
    @patch("pymol.ai_pdb_search._fetch_all_metadata")
    def test_single_result(self, mock_meta, mock_ids):
        mock_ids.return_value = ["1UBQ"]
        mock_meta.return_value = [
            {"pdb_id": "1UBQ", "title": "UBIQUITIN", "organism": None, "resolution": None},
        ]
        results = search_pdb("ubiquitin", max_results=1)
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["pdb_id"], "1UBQ")


class TestFetchAllMetadata(unittest.TestCase):
    """Tests for _fetch_all_metadata() GraphQL parsing."""

    @patch("urllib.request.urlopen")
    def test_parses_graphql_response(self, mock_urlopen):
        graphql_body = {
            "data": {
                "entries": [
                    {
                        "rcsb_id": "1UBQ",
                        "struct": {"title": "UBIQUITIN"},
                        "rcsb_entry_info": {
                            "resolution_combined": [1.8],
                            "organism_scientific_name": ["Homo sapiens"],
                        },
                    },
                ]
            }
        }
        mock_urlopen.return_value = _make_urlopen_response(graphql_body)
        results = _fetch_all_metadata(["1UBQ"])
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["pdb_id"], "1UBQ")
        self.assertEqual(results[0]["title"], "UBIQUITIN")
        self.assertAlmostEqual(results[0]["resolution"], 1.8)
        self.assertEqual(results[0]["organism"], "Homo sapiens")

    @patch("urllib.request.urlopen")
    def test_handles_null_entry(self, mock_urlopen):
        graphql_body = {
            "data": {
                "entries": [
                    None,
                    {"rcsb_id": "4HHB", "struct": {"title": "HEMOGLOBIN"}, "rcsb_entry_info": {}},
                ]
            }
        }
        mock_urlopen.return_value = _make_urlopen_response(graphql_body)
        results = _fetch_all_metadata(["XXXX", "4HHB"])
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["pdb_id"], "4HHB")

    @patch("urllib.request.urlopen")
    def test_handles_missing_resolution(self, mock_urlopen):
        graphql_body = {
            "data": {
                "entries": [
                    {
                        "rcsb_id": "1UBQ",
                        "struct": {"title": "UBIQUITIN"},
                        "rcsb_entry_info": {
                            "resolution_combined": None,
                            "organism_scientific_name": None,
                        },
                    },
                ]
            }
        }
        mock_urlopen.return_value = _make_urlopen_response(graphql_body)
        results = _fetch_all_metadata(["1UBQ"])
        self.assertEqual(len(results), 1)
        self.assertIsNone(results[0]["resolution"])
        self.assertIsNone(results[0]["organism"])

    def test_empty_ids(self):
        results = _fetch_all_metadata([])
        self.assertEqual(results, [])

    @patch("urllib.request.urlopen")
    def test_scalar_resolution(self, mock_urlopen):
        graphql_body = {
            "data": {
                "entries": [
                    {
                        "rcsb_id": "1UBQ",
                        "struct": {"title": "T"},
                        "rcsb_entry_info": {
                            "resolution_combined": 2.0,
                            "organism_scientific_name": "E. coli",
                        },
                    },
                ]
            }
        }
        mock_urlopen.return_value = _make_urlopen_response(graphql_body)
        results = _fetch_all_metadata(["1UBQ"])
        self.assertAlmostEqual(results[0]["resolution"], 2.0)
        # Scalar string organism passes through as-is (only lists are unpacked)
        self.assertEqual(results[0]["organism"], "E. coli")


class TestSearchIds(unittest.TestCase):
    """Tests for _search_ids()."""

    @patch("urllib.request.urlopen")
    def test_returns_ids(self, mock_urlopen):
        body = {"result_set": [{"identifier": "1UBQ"}, {"identifier": "4HHB"}]}
        mock_urlopen.return_value = _make_urlopen_response(body)
        ids = _search_ids("hemoglobin", 5)
        self.assertEqual(ids, ["1UBQ", "4HHB"])

    @patch("urllib.request.urlopen")
    def test_empty_result_set(self, mock_urlopen):
        body = {"result_set": []}
        mock_urlopen.return_value = _make_urlopen_response(body)
        ids = _search_ids("xyznonexistent", 5)
        self.assertEqual(ids, [])

    @patch("urllib.request.urlopen", side_effect=OSError("network error"))
    def test_network_error_returns_empty(self, mock_urlopen):
        ids = _search_ids("test", 5)
        self.assertEqual(ids, [])


if __name__ == "__main__":
    unittest.main()
