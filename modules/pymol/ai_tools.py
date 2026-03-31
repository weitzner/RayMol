"""AI tool definitions and implementations for PyMOL agentic chat.

Defines tools in two formats:
1. Claude Agent SDK format using @tool decorator and create_sdk_mcp_server
2. Legacy Anthropic tool_use schema (TOOL_DEFINITIONS + execute_tool) as fallback

The SDK path is preferred when claude_agent_sdk is installed; otherwise the
legacy path is used automatically.
"""

import asyncio
import json
import base64
import os

# ---------------------------------------------------------------------------
# SDK availability check
# ---------------------------------------------------------------------------

try:
    from claude_agent_sdk import tool, create_sdk_mcp_server, ToolAnnotations
    _HAS_SDK = True
except ImportError:
    _HAS_SDK = False

# ---------------------------------------------------------------------------
# Main-thread helper
# ---------------------------------------------------------------------------

def _run_on_main(func):
    """Run *func* on the main thread, returning its result.

    Tries to import run_on_main_thread from ai_chat_ui (provided by Agent A).
    If unavailable (headless / testing), calls func directly.
    """
    try:
        from pymol.ai_chat_ui import run_on_main_thread
        return run_on_main_thread(func)
    except (ImportError, AttributeError):
        # Fallback: call directly (may deadlock if called from worker thread
        # in a GUI session, but allows headless/test usage).
        return func()


# ---------------------------------------------------------------------------
# Legacy tool definitions (Anthropic tool_use schema format)
# ---------------------------------------------------------------------------

TOOL_DEFINITIONS = [
    {
        "name": "get_session_state",
        "description": (
            "Retrieve the current state of the PyMOL session including all "
            "loaded objects (molecules, maps, groups, etc.) with atom counts, "
            "named selections with atom counts, the current camera view matrix "
            "(18 floats: 9 rotation, 3 position, 3 origin, 3 clipping/fog), "
            "and the viewport dimensions in pixels. Use this tool whenever you "
            "need to understand what the user currently has loaded or how the "
            "scene is oriented."
        ),
        "input_schema": {
            "type": "object",
            "properties": {},
            "required": []
        }
    },
    {
        "name": "execute_command",
        "description": (
            "Run a PyMOL command and return its text output. Use this ONLY when "
            "you need to READ the result before deciding your next step (e.g., "
            "checking distances, listing chains, reading settings). "
            "Do NOT use this for actions like fetch, color, show, align, super — "
            "put those in the 'script' field of your JSON response instead. "
            "Using the script field is faster and avoids wasting tool rounds."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": (
                        "One or more PyMOL commands separated by newlines. "
                        "Example: 'fetch 1ubq\\nshow cartoon\\ncolor green, ss h'"
                    )
                }
            },
            "required": ["command"]
        }
    },
    {
        "name": "capture_viewport",
        "description": (
            "Capture a screenshot of the current PyMOL viewport as a PNG image. "
            "The image is returned as a base64-encoded string. You can optionally "
            "specify width and height in pixels; if omitted the current viewport "
            "size is used. Use this tool when the user asks you to look at, "
            "analyze, or comment on the current visualization."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "width": {
                    "type": "integer",
                    "description": "Image width in pixels. Defaults to current viewport width."
                },
                "height": {
                    "type": "integer",
                    "description": "Image height in pixels. Defaults to current viewport height."
                }
            },
            "required": []
        }
    },
    {
        "name": "search_pdb",
        "description": (
            "Search the RCSB Protein Data Bank for structures matching a text "
            "query. Returns a list of matching PDB entries with their ID, title, "
            "source organism, and resolution. Use this tool when the user asks "
            "about available structures, wants to find a protein, or needs help "
            "choosing which PDB entry to load."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": (
                        "Search query text, e.g. 'human hemoglobin', "
                        "'CRISPR Cas9', 'insulin receptor'."
                    )
                },
                "max_results": {
                    "type": "integer",
                    "description": "Maximum number of results to return (default 5, max 25)."
                }
            },
            "required": ["query"]
        }
    },
]


# ---------------------------------------------------------------------------
# Tool implementations (shared by both SDK and legacy paths)
# ---------------------------------------------------------------------------

def _impl_get_session_state(cmd):
    """Gather objects, selections, view, and viewport from the PyMOL session."""

    def _gather():
        state = {"objects": [], "selections": [], "view": None, "viewport": None}

        # Objects
        try:
            names = cmd.get_names('objects') or []
            for name in names:
                try:
                    obj_type = cmd.get_type(name)
                except Exception:
                    obj_type = "unknown"
                try:
                    count = cmd.count_atoms(name)
                except Exception:
                    count = 0
                state["objects"].append({
                    "name": name,
                    "type": obj_type,
                    "atom_count": count
                })
        except Exception:
            pass

        # Named selections
        try:
            sels = cmd.get_names('public_selections') or []
            for name in sels:
                try:
                    count = cmd.count_atoms(name)
                except Exception:
                    count = 0
                state["selections"].append({
                    "name": name,
                    "atom_count": count
                })
        except Exception:
            pass

        # Camera view (18 floats)
        try:
            view = cmd.get_view()
            state["view"] = list(view)
        except Exception:
            pass

        # Viewport size
        try:
            vp = cmd.get_viewport()
            state["viewport"] = {"width": vp[0], "height": vp[1]}
        except Exception:
            pass

        return state

    return _run_on_main(_gather)


def _impl_execute_command(command_text, cmd):
    """Execute PyMOL commands on the main thread, returning results + console output."""
    lines = [l.strip() for l in command_text.splitlines() if l.strip()]

    if not lines:
        return "No commands to execute."

    results = []
    feedback_lines = []

    def _exec():
        # Drain any stale feedback first
        try:
            cmd._get_feedback()
        except Exception:
            pass

        for line in lines:
            try:
                cmd.do(line, 0, 1)
                results.append(f"OK: {line}")
            except Exception as exc:
                results.append(f"Error: {line} => {exc}")

        # Collect console output/feedback generated by the commands
        try:
            fb = cmd._get_feedback()
            if fb:
                for item in fb:
                    if isinstance(item, (list, tuple)):
                        for s in item:
                            if isinstance(s, str) and s.strip():
                                feedback_lines.append(s.strip())
                    elif isinstance(item, str) and item.strip():
                        feedback_lines.append(item.strip())
        except Exception:
            pass

    _run_on_main(_exec)

    output = "\n".join(results)
    if feedback_lines:
        output += "\n\nConsole output:\n" + "\n".join(feedback_lines)
    return output if output else "No commands executed."


def _impl_capture_viewport(width, height, cmd):
    """Capture the PyMOL viewport as base64 PNG bytes (or None on failure)."""
    png_data = [None]

    def _capture():
        # First try: cmd.png(None, ...) returns PNG bytes directly
        try:
            result = cmd.png(None, width, height, ray=0, quiet=1)
            if result and isinstance(result, (bytes, bytearray)) and len(result) > 0:
                png_data[0] = bytes(result)
                return
        except Exception:
            pass

        # Fallback: write to a temp file and read it back
        try:
            tmp_path = '/tmp/_pymol_ai_capture.png'
            cmd.png(tmp_path, width, height, ray=0, quiet=1)
            import time
            time.sleep(0.3)
            if os.path.exists(tmp_path):
                with open(tmp_path, 'rb') as f:
                    png_data[0] = f.read()
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
        except Exception:
            pass

    _run_on_main(_capture)
    return png_data[0]


def _impl_search_pdb(query, max_results):
    """Search the RCSB PDB. Does NOT require main thread (pure network)."""
    max_results = max(1, min(25, max_results))

    from pymol.ai_pdb_search import search_pdb
    return search_pdb(query, max_results=max_results)


# ---------------------------------------------------------------------------
# SDK tool definitions (only created when claude_agent_sdk is available)
# ---------------------------------------------------------------------------

pymol_server = None

if _HAS_SDK:
    from pymol import cmd as _cmd

    @tool(
        "get_session_state",
        "Retrieve the current state of the PyMOL session including all "
        "loaded objects (molecules, maps, groups, etc.) with atom counts, "
        "named selections with atom counts, the current camera view matrix "
        "(18 floats: 9 rotation, 3 position, 3 origin, 3 clipping/fog), "
        "and the viewport dimensions in pixels. Use this tool whenever you "
        "need to understand what the user currently has loaded or how the "
        "scene is oriented.",
        {},
        annotations=ToolAnnotations(readOnlyHint=True),
    )
    async def sdk_get_session_state(args):
        try:
            state = await asyncio.to_thread(_impl_get_session_state, _cmd)
            return {"content": [{"type": "text", "text": json.dumps(state, indent=2)}]}
        except Exception as exc:
            return {"content": [{"type": "text", "text": f"Error: {exc}"}], "is_error": True}

    @tool(
        "execute_command",
        "Execute one or more PyMOL commands and return the result of each. "
        "Commands are separated by newlines and executed sequentially. Each "
        "command is run via cmd.do() on the main thread. Returns 'OK' or an "
        "error message for each command. Use this when you need to run a "
        "command and confirm it succeeded, rather than putting commands in "
        "the JSON 'script' field which executes silently.",
        {"command": str},
    )
    async def sdk_execute_command(args):
        command_text = args.get("command", "")
        if not command_text:
            return {"content": [{"type": "text", "text": "No commands to execute."}], "is_error": True}
        try:
            result = await asyncio.to_thread(_impl_execute_command, command_text, _cmd)
            return {"content": [{"type": "text", "text": result}]}
        except Exception as exc:
            return {"content": [{"type": "text", "text": f"Error: {exc}"}], "is_error": True}

    @tool(
        "capture_viewport",
        "Capture a screenshot of the current PyMOL viewport as a PNG image. "
        "The image is returned as a base64-encoded string. You can optionally "
        "specify width and height in pixels; if omitted the current viewport "
        "size is used. Use this tool when the user asks you to look at, "
        "analyze, or comment on the current visualization.",
        {"width": int, "height": int},
        annotations=ToolAnnotations(readOnlyHint=True),
    )
    async def sdk_capture_viewport(args):
        width = args.get("width", 0) or 0
        height = args.get("height", 0) or 0
        try:
            png_bytes = await asyncio.to_thread(_impl_capture_viewport, width, height, _cmd)
            if png_bytes and len(png_bytes) > 0:
                b64 = base64.b64encode(png_bytes).decode('ascii')
                return {"content": [{"type": "image", "data": b64, "mimeType": "image/png"}]}
            else:
                return {"content": [{"type": "text", "text": "Error: Failed to capture viewport image."}], "is_error": True}
        except Exception as exc:
            return {"content": [{"type": "text", "text": f"Error: {exc}"}], "is_error": True}

    @tool(
        "search_pdb",
        "Search the RCSB Protein Data Bank for structures matching a text "
        "query. Returns a list of matching PDB entries with their ID, title, "
        "source organism, and resolution. Use this tool when the user asks "
        "about available structures, wants to find a protein, or needs help "
        "choosing which PDB entry to load.",
        {"query": str, "max_results": int},
        annotations=ToolAnnotations(readOnlyHint=True),
    )
    async def sdk_search_pdb(args):
        query = args.get("query", "")
        max_results = args.get("max_results", 5)
        if not query:
            return {"content": [{"type": "text", "text": json.dumps({"error": "No query provided."})}], "is_error": True}
        try:
            results = await asyncio.to_thread(_impl_search_pdb, query, max_results)
            return {"content": [{"type": "text", "text": json.dumps(results, indent=2)}]}
        except Exception as exc:
            return {"content": [{"type": "text", "text": json.dumps({"error": f"PDB search failed: {exc}"})}], "is_error": True}

    # Build the MCP server
    pymol_server = create_sdk_mcp_server(
        name="pymol",
        version="1.0.0",
        tools=[sdk_get_session_state, sdk_execute_command, sdk_capture_viewport, sdk_search_pdb],
    )


# ---------------------------------------------------------------------------
# Legacy dispatcher (fallback when SDK is not available)
# ---------------------------------------------------------------------------

def _tool_get_session_state(tool_input, cmd):
    result = _impl_get_session_state(cmd)
    return json.dumps(result, indent=2)


def _tool_execute_command(tool_input, cmd):
    command_text = tool_input.get("command", "")
    return _impl_execute_command(command_text, cmd)


def _tool_capture_viewport(tool_input, cmd):
    width = tool_input.get("width", 0) or 0
    height = tool_input.get("height", 0) or 0
    png_bytes = _impl_capture_viewport(width, height, cmd)
    if png_bytes and len(png_bytes) > 0:
        return base64.b64encode(png_bytes).decode('ascii')
    else:
        return "Error: Failed to capture viewport image."


def _tool_search_pdb(tool_input, cmd):
    query = tool_input.get("query", "")
    max_results = tool_input.get("max_results", 5)
    if not query:
        return json.dumps({"error": "No query provided."})
    max_results = max(1, min(25, max_results))
    try:
        results = _impl_search_pdb(query, max_results)
        return json.dumps(results, indent=2)
    except Exception as exc:
        return json.dumps({"error": f"PDB search failed: {exc}"})


_TOOL_HANDLERS = {
    "get_session_state": _tool_get_session_state,
    "execute_command": _tool_execute_command,
    "capture_viewport": _tool_capture_viewport,
    "search_pdb": _tool_search_pdb,
}


def execute_tool(tool_name, tool_input, cmd_module):
    """Dispatch a tool call to the appropriate handler.

    Parameters
    ----------
    tool_name : str
        Name of the tool to execute (must match a key in TOOL_DEFINITIONS).
    tool_input : dict
        The input parameters for the tool call.
    cmd_module : object
        The PyMOL cmd module (or equivalent) to pass to the handler.

    Returns
    -------
    str or dict
        The result of the tool execution, typically a JSON string or an
        error message string.
    """
    handler = _TOOL_HANDLERS.get(tool_name)
    if handler is None:
        return f"Error: Unknown tool '{tool_name}'."

    try:
        return handler(tool_input or {}, cmd_module)
    except Exception as exc:
        return f"Error executing tool '{tool_name}': {exc}"
