"""RCSB PDB search client for PyMOL AI chat.

Provides a simple interface to search the Protein Data Bank using the
RCSB Search API v2 and retrieve entry metadata. Uses only stdlib
(urllib) to avoid external dependencies.
"""

import json
import re
import urllib.request
import urllib.error

_SEARCH_URL = "https://search.rcsb.org/rcsbsearch/v2/query"
_ENTRY_URL = "https://data.rcsb.org/rest/v1/core/entry/{pdb_id}"

# Timeout for individual HTTP requests (seconds)
_REQUEST_TIMEOUT = 5

# Pattern for a 4-character PDB ID (e.g., 1M47, 3BPL)
_PDB_ID_RE = re.compile(r'^[0-9][A-Za-z0-9]{3}$')


def _extract_pdb_ids(query):
    """Extract PDB IDs from a query string. Returns list of uppercase IDs found."""
    tokens = re.split(r'[\s,;]+', query.strip())
    return [t.upper() for t in tokens if _PDB_ID_RE.match(t)]


def search_pdb(query, max_results=5):
    """Search the RCSB PDB for structures matching a text query.

    If the query contains PDB IDs (4-character codes like 1M47), fetches
    metadata directly without the slow full-text search (~0.5s vs ~10s).

    Parameters
    ----------
    query : str
        Free-text search query (e.g. 'human hemoglobin', 'CRISPR Cas9')
        or PDB IDs (e.g. '1M47', '1M47 1HIK').
    max_results : int, optional
        Maximum number of results to return (default 5, clamped to 1-25).

    Returns
    -------
    list of dict
        Each dict contains:
        - pdb_id (str): 4-character PDB identifier
        - title (str): Structure title
        - organism (str or None): Source organism scientific name
        - resolution (float or None): Resolution in angstroms
    """
    max_results = max(1, min(25, int(max_results)))

    # Fast path: if the query looks like PDB ID(s), skip full-text search
    pdb_ids = _extract_pdb_ids(query)
    if pdb_ids:
        return _fetch_all_metadata(pdb_ids[:max_results])

    # Slow path: full-text search
    pdb_ids = _search_ids(query, max_results)

    if not pdb_ids:
        return []

    # Step 2: Fetch metadata for all IDs in one GraphQL request
    results = _fetch_all_metadata(pdb_ids)

    return results


def _search_ids(query, max_results):
    """POST a full-text search to RCSB and return a list of PDB IDs.

    Returns
    -------
    list of str
        PDB IDs matching the query, up to max_results.
    """
    payload = {
        "query": {
            "type": "terminal",
            "service": "full_text",
            "parameters": {
                "value": query
            }
        },
        "return_type": "entry",
        "request_options": {
            "paginate": {
                "start": 0,
                "rows": max_results
            }
        }
    }

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        _SEARCH_URL,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=_REQUEST_TIMEOUT) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        # 204 No Content or other non-200 = no results
        return []
    except (urllib.error.URLError, OSError, json.JSONDecodeError):
        return []

    result_set = body.get("result_set", [])
    return [entry["identifier"] for entry in result_set if "identifier" in entry]


def _fetch_all_metadata(pdb_ids):
    """Fetch metadata for multiple PDB entries in a single GraphQL request.

    Returns list of dicts with pdb_id, title, organism, resolution.
    """
    if not pdb_ids:
        return []

    # Use RCSB GraphQL API — one request for all entries
    graphql_url = "https://data.rcsb.org/graphql"
    query = """
    query($ids: [String!]!) {
      entries(entry_ids: $ids) {
        rcsb_id
        struct { title }
        rcsb_entry_info {
          resolution_combined
          organism_scientific_name
        }
      }
    }
    """
    payload = json.dumps({"query": query, "variables": {"ids": pdb_ids}}).encode("utf-8")
    req = urllib.request.Request(
        graphql_url, data=payload,
        headers={"Content-Type": "application/json"}, method="POST")

    try:
        with urllib.request.urlopen(req, timeout=_REQUEST_TIMEOUT) as resp:
            body = json.loads(resp.read().decode("utf-8"))
        entries = body.get("data", {}).get("entries", [])
        results = []
        for entry in entries:
            if not entry:
                continue
            pdb_id = entry.get("rcsb_id", "")
            title = None
            struct = entry.get("struct", {})
            if struct:
                title = struct.get("title")
            organism = None
            resolution = None
            info = entry.get("rcsb_entry_info", {})
            if info:
                organism = info.get("organism_scientific_name")
                if isinstance(organism, list) and organism:
                    organism = organism[0]
                res = info.get("resolution_combined")
                if isinstance(res, list) and res:
                    try:
                        resolution = float(res[0])
                    except (ValueError, TypeError):
                        pass
                elif isinstance(res, (int, float)):
                    resolution = float(res)
            results.append({
                "pdb_id": pdb_id, "title": title,
                "organism": organism, "resolution": resolution,
            })
        return results
    except Exception:
        # Fallback: fetch individually
        return [_fetch_entry_metadata(pid) for pid in pdb_ids]


def _fetch_entry_metadata(pdb_id):
    """GET metadata for a single PDB entry (fallback).

    Returns dict with pdb_id, title, organism, resolution.
    """
    url = _ENTRY_URL.format(pdb_id=pdb_id)
    req = urllib.request.Request(url, method="GET")

    try:
        with urllib.request.urlopen(req, timeout=_REQUEST_TIMEOUT) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.HTTPError, urllib.error.URLError, OSError,
            json.JSONDecodeError):
        return {"pdb_id": pdb_id, "title": None, "organism": None, "resolution": None}

    title = None
    struct = body.get("struct", {})
    if isinstance(struct, dict):
        title = struct.get("title")

    organism = None
    entry_info = body.get("rcsb_entry_info", {})
    if isinstance(entry_info, dict):
        # Try the list form first (can be a list of names)
        org = entry_info.get("organism_scientific_name")
        if isinstance(org, list) and org:
            organism = org[0]
        elif isinstance(org, str):
            organism = org

    # If organism not in rcsb_entry_info, try polymer_entities
    if organism is None:
        try:
            entities = body.get("polymer_entities", [])
            if entities and isinstance(entities, list):
                src = entities[0].get("rcsb_entity_source_organism", [])
                if src and isinstance(src, list):
                    organism = src[0].get("ncbi_scientific_name")
        except (KeyError, IndexError, TypeError):
            pass

    # Extract resolution
    resolution = None
    if isinstance(entry_info, dict):
        res = entry_info.get("resolution_combined")
        if isinstance(res, list) and res:
            try:
                resolution = float(res[0])
            except (ValueError, TypeError):
                pass
        elif isinstance(res, (int, float)):
            resolution = float(res)

    return {
        "pdb_id": pdb_id,
        "title": title,
        "organism": organism,
        "resolution": resolution,
    }
