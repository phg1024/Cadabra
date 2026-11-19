#!/usr/bin/env python3
"""A tiny agent for trying Cadabra's agent plugins: it says back what it heard.

It speaks the API that examples/echo-agent/plugin/plugin.json describes (see docs/plugins.md):
  GET  /health                     200 when it's up (and the token is right)
  POST /text   {"text": "..."}     {"reply": "...", "conversation_id": "..."}; with
                                   Accept: application/x-ndjson it first streams what it is "doing"
  POST /speech {"text", "language"}  a WAV of the text, made with macOS's `say`

    python3 agent.py                 # http://localhost:8787, no token
    TOKEN=secret python3 agent.py    # then put "secret" in Cadabra › Settings › Agent › Token
"""
import json
import os
import subprocess
import tempfile
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8787"))
TOKEN = os.environ.get("TOKEN", "")
turns = {}   # conversation id -> how many times it was asked


class Agent(BaseHTTPRequestHandler):
    def send_json(self, status, body):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def allowed(self):
        if TOKEN and self.headers.get("Authorization") != f"Bearer {TOKEN}":
            self.send_json(401, {"error": "wrong token"})
            return False
        return True

    def body(self):
        return json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")

    def do_GET(self):
        if self.path != "/health":
            return self.send_json(404, {"error": "no such path"})
        if self.allowed():
            self.send_json(200, {"ok": True})

    def do_POST(self):
        if not self.allowed():
            return
        if self.path == "/text":
            return self.text()
        if self.path == "/speech":
            return self.speech()
        self.send_json(404, {"error": "no such path"})

    def text(self):
        words = str(self.body().get("text", "")).strip()
        if not words:
            return self.send_json(400, {"error": "say something first"})
        conversation = self.headers.get("X-Conversation-Id") or uuid.uuid4().hex
        turns[conversation] = turns.get(conversation, 0) + 1
        chinese = any("一" <= ch <= "鿿" for ch in words)
        reply = (f"你说的是：{words}（这一段对话里的第 {turns[conversation]} 句）" if chinese
                 else f"You said: {words} (turn {turns[conversation]} of this conversation)")
        result = {"text": words, "reply": reply, "conversation_id": conversation}
        if "application/x-ndjson" not in self.headers.get("Accept", ""):
            return self.send_json(200, result)
        # Streamed: what it is "doing", one JSON object per line, then the answer.
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
        self.end_headers()
        for state in ("thinking", "researching"):
            self.wfile.write((json.dumps({"type": "activity", "state": state}) + "\n").encode())
            self.wfile.flush()
            time.sleep(0.8)
        self.wfile.write((json.dumps({"type": "result", **result}, ensure_ascii=False) + "\n").encode())

    def speech(self):
        text = str(self.body().get("text", "")).strip()
        if not text:
            return self.send_json(400, {"error": "nothing to say"})
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "speech.wav")
            subprocess.run(["say", "-o", path, "--file-format=WAVE", "--data-format=LEI16@22050", text], check=True)
            data = open(path, "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    print(f"echo agent on http://localhost:{PORT}" + (" (token required)" if TOKEN else ""))
    ThreadingHTTPServer(("127.0.0.1", PORT), Agent).serve_forever()
