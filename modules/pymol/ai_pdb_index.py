"""Local PDB index for fast structure search.

Downloads RCSB's entries.idx (~56MB, ~251K entries) and keeps it in
~/Library/Application Support/AiMOL/. Refreshed weekly in the background.
Provides <100ms in-memory text search vs 5-20s per RCSB API call.
"""

import os
import sys
import time
import threading
import urllib.request

INDEX_URL = "https://files.rcsb.org/pub/pdb/derived_data/index/entries.idx"
INDEX_DIR = os.path.expanduser("~/Library/Application Support/AiMOL")
INDEX_FILE = "pdb_entries.idx"
MAX_AGE_DAYS = 7

# In-memory index: parallel lists for fast search
_pdb_ids = []      # list of str
_titles = []       # list of str (compound field)
_organisms = []    # list of str or None
_resolutions = []  # list of float or None
_search_text = []  # list of str (lowercase, for matching)
_loaded = False
_lock = threading.Lock()


def _log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"[ai_pdb_index {ts}] {msg}", file=sys.stderr, flush=True)


def _index_path():
    return os.path.join(INDEX_DIR, INDEX_FILE)


def is_stale():
    """Return True if the index file is missing or older than MAX_AGE_DAYS."""
    path = _index_path()
    if not os.path.isfile(path):
        return True
    age = time.time() - os.path.getmtime(path)
    return age > MAX_AGE_DAYS * 86400


def download_index(progress_callback=None):
    """Download entries.idx from RCSB. Returns True on success."""
    os.makedirs(INDEX_DIR, exist_ok=True)
    path = _index_path()
    tmp = path + ".tmp"

    _log(f"Downloading PDB index...")
    t0 = time.time()

    try:
        req = urllib.request.Request(INDEX_URL)
        with urllib.request.urlopen(req, timeout=600) as resp:
            total = int(resp.headers.get("Content-Length", 0))
            downloaded = 0
            last_report = 0

            with open(tmp, "wb") as f:
                while True:
                    chunk = resp.read(131072)
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)

                    if progress_callback and total > 0:
                        now = time.time()
                        if now - last_report >= 2.0:
                            pct = int(100 * downloaded / total)
                            progress_callback(f"Downloading PDB index... {pct}%")
                            last_report = now

        # Atomic rename
        os.replace(tmp, path)
        elapsed = time.time() - t0
        size_mb = os.path.getsize(path) / (1024 * 1024)
        _log(f"PDB index downloaded: {size_mb:.1f} MB in {elapsed:.1f}s")
        return True

    except Exception as e:
        _log(f"Failed to download PDB index: {e}")
        try:
            if os.path.isfile(tmp):
                os.unlink(tmp)
        except OSError:
            pass
        return False


def load_index():
    """Parse the index file into memory. Returns True on success."""
    global _pdb_ids, _titles, _organisms, _resolutions, _search_text, _loaded
    path = _index_path()

    if not os.path.isfile(path):
        _log("No index file to load")
        return False

    with _lock:
        if _loaded:
            return True

        t0 = time.time()
        ids = []
        titles = []
        orgs = []
        ress = []
        searches = []

        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                for i, line in enumerate(f):
                    if i < 2:
                        continue
                    parts = line.split("\t")
                    if len(parts) < 5:
                        continue

                    pdb_id = parts[0].strip()
                    if len(pdb_id) != 4:
                        continue

                    header = parts[1].strip() if len(parts) > 1 else ""
                    compound = parts[3].strip() if len(parts) > 3 else ""
                    source = parts[4].strip() if len(parts) > 4 else ""
                    res_str = parts[6].strip() if len(parts) > 6 else ""

                    res_float = None
                    try:
                        res_float = float(res_str)
                    except (ValueError, TypeError):
                        pass

                    ids.append(pdb_id.upper())
                    titles.append(compound or header)
                    orgs.append(source or None)
                    ress.append(res_float)
                    searches.append(f"{header} {compound} {source}".lower())

            _pdb_ids = ids
            _titles = titles
            _organisms = orgs
            _resolutions = ress
            _search_text = searches
            _loaded = True
            _log(f"PDB index loaded: {len(_pdb_ids)} entries in {time.time()-t0:.1f}s")
            return True

        except Exception as e:
            _log(f"Failed to load PDB index: {e}")
            return False


def search(query, max_results=5):
    """Search the in-memory index. Returns list of dicts."""
    if not _pdb_ids:
        return []

    words = query.lower().split()
    if not words:
        return []

    query_lower = query.lower()
    scored = []

    for i, st in enumerate(_search_text):
        # Count matching words
        score = 0
        for w in words:
            if w in st:
                score += 1
        if score == 0:
            continue

        # Bonus for all words matching
        if score == len(words):
            score += 10
        # Bonus for exact phrase
        if query_lower in st:
            score += 5
        # Small bonus for having resolution (crystallography)
        res = _resolutions[i]
        if res is not None and res > 0:
            score += max(0, 5 - res) * 0.1

        scored.append((score, i))

    # Sort by score desc, resolution asc
    scored.sort(key=lambda x: (-x[0], _resolutions[x[1]] or 99))

    results = []
    for _, i in scored[:max_results]:
        results.append({
            "pdb_id": _pdb_ids[i],
            "title": _titles[i],
            "organism": _organisms[i],
            "resolution": _resolutions[i],
        })
    return results


def ensure_loaded():
    """Load index from disk if not already loaded. Returns True if loaded."""
    if _loaded:
        return True
    return load_index()
