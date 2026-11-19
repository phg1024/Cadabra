# Echo: an example agent plugin

A tiny agent and the plugin that connects Cadabra to it, to try the agent key or to start your own
(docs/plugins.md describes plugins). The agent says back what it heard; before answering it streams
two made-up activities ("thinking", "researching") so a look has something to show; it reads replies
aloud with macOS's `say`.

```bash
python3 examples/echo-agent/agent.py      # http://localhost:8787; TOKEN=… to require a token
mkdir -p ~/Library/Application\ Support/Cadabra/Plugins
cp -R examples/echo-agent/plugin ~/Library/Application\ Support/Cadabra/Plugins/echo
```

Then Settings › Agent › Agent plugin › Echo (example), choose an agent key, and hold it while you talk.

- `agent.py`: the agent (Python standard library only).
- `plugin/plugin.json`: its name, window size, and the one host it may reach.
- `plugin/index.html`: everything else, as a plugin does it: the window's contents (the words as you
  talk, then editable; Return sends, esc closes), the request to the agent with its streamed
  activity, the answer, reading it aloud, an orb that breathes with the voice, and the token (⚙︎).
