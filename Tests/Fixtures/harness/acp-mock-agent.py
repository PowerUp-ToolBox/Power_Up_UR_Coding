# The scripted ACP agent: JSON-RPC 2.0, one JSON object per line over stdio.
# It answers initialize, session/new, session/prompt (a thought, a chunk, a
# tool call and a permission request, then the reply and usage) and
# session/set_model, with no real harness and no network.
#
# Both suites run it in place: Swift's ACPAdapterIntegrationTests through the
# app's ACPAdapter, and the Rust core's tests. The lines it prints are copied
# byte for byte into the "mock agent: ..." cases of acp-adapter.json.
#
# --record PATH appends one JSON object per line to PATH:
# {"received": <a line read, without its line break>} and
# {"sent": <a line written, without its newline>}, so a test can check the
# exchange against those cases.
import json, sys

record = None
if "--record" in sys.argv:
    record = open(sys.argv[sys.argv.index("--record") + 1], "a")

def note(key, text):
    if record is not None:
        record.write(json.dumps({key: text}) + "\n")
        record.flush()

def send(obj):
    text = json.dumps(obj)
    note("sent", text)
    sys.stdout.write(text + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    note("received", line.rstrip("\r\n"))
    line = line.strip()
    if not line:
        continue
    m = json.loads(line)
    method, mid = m.get("method"), m.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": 1,
            "agentInfo": {"name": "MockAgent", "version": "1.0"}}})
    elif method == "session/new":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "sessionId": "mock-session",
            "models": {"currentModelId": "mock/model-1"}}})
    elif method == "session/prompt":
        sid = m["params"]["sessionId"]
        def update(u):
            send({"jsonrpc": "2.0", "method": "session/update",
                  "params": {"sessionId": sid, "update": u}})
        update({"sessionUpdate": "agent_thought_chunk",
                "content": {"type": "text", "text": "thinking"}})
        update({"sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": "Working. "}})
        update({"sessionUpdate": "tool_call", "toolCallId": "t1",
                "title": "Edit File", "kind": "edit",
                "locations": [{"path": "/tmp/a.swift", "line": 1}]})
        send({"jsonrpc": "2.0", "id": 100, "method": "session/request_permission",
              "params": {"sessionId": sid,
                         "toolCall": {"title": "Edit a.swift", "kind": "edit",
                                      "rawInput": {"file_path": "/tmp/a.swift"}},
                         "options": [
                             {"optionId": "allow-always", "name": "Always", "kind": "allow_always"},
                             {"optionId": "allow-once", "name": "Once", "kind": "allow_once"},
                             {"optionId": "reject-once", "name": "No", "kind": "reject_once"}]}})
        chosen = "cancelled"
        for reply_line in sys.stdin:
            note("received", reply_line.rstrip("\r\n"))
            r = json.loads(reply_line)
            if r.get("id") == 100:
                outcome = r.get("result", {}).get("outcome", {})
                if outcome.get("outcome") == "selected":
                    chosen = outcome.get("optionId", "cancelled")
                break
        update({"sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": "choice=" + chosen}})
        send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn",
              "usage": {"inputTokens": 100, "outputTokens": 50}}})
    elif method == "session/set_model":
        if m["params"].get("modelId") == "bad":
            send({"jsonrpc": "2.0", "id": mid,
                  "error": {"code": -32602, "message": "unknown model"}})
        else:
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
