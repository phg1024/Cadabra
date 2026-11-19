# Agent plugins

The agent key (Settings › Agent) hands what you say to an agent. Cadabra knows no agent by itself:
each one comes as a **plugin**, and Cadabra's part is small. While the key is held it records, it
recognizes the words, and it tells the plugin's page what it hears. Everything else is the plugin's:
what its window shows, whether and how you confirm before anything is sent, talking to its agent,
showing the answer, reading it aloud, its look, and its token or other settings.

A working example to try or start from is in [`examples/echo-agent`](../examples/echo-agent): a tiny
agent that says back what it heard, and its plugin.

## A plugin is a folder

```
~/Library/Application Support/Cadabra/Plugins/<id>/
  plugin.json
  index.html        (and whatever it loads from the folder)
```

`plugin.json`:

```json
{
  "name": "Echo",
  "entry": "index.html",
  "width": 440,
  "height": 200,
  "hosts": ["http://localhost:8787"]
}
```

| Key | Meaning | Default |
|---|---|---|
| `name` | Shown in Settings. | the folder's name |
| `entry` | The page, inside the folder. | `index.html` |
| `width`, `height` | The window's size to start with, 120–900 points; the page can change it. | 440, 180 |
| `hosts` | The only places the page may reach: scheme, host and port, e.g. `"https://agent.example.com"`. | none |
| `settings` | `true` if the page has settings of its own (a token, say): Settings › Agent then shows **Plugin settings…**, which opens the window and tells the page `settings`. | `false` |
| `position` | Where the window opens: `"text"`, next to where you are typing, or `"center"`, the middle of the screen. | `"text"` |

Pick the plugin in Settings › Agent; **Open the plugins folder** takes you there.

## The window

When the agent key goes down, Cadabra opens a borderless window near where you are typing (or high in
the middle of the screen), or in the middle of the screen if `position` is `"center"`, and shows the page in it. The page's background is transparent: paint your
own card, corners and all. The window takes the keyboard while it is open, and the app you were in
gets it back when it closes.

## What the page is told

Cadabra defines `window.cadabra` before the page's scripts run. Listen with `cadabra.on(type, fn)`:

| Event | When |
|---|---|
| `{type: "listen"}` | The agent key went down; the window has just opened. |
| `{type: "partial", text}` | What has been recognized so far, about once a second while you talk. |
| `{type: "final", text}` | You let go; these are the words. |
| `{type: "level", value}` | How loud the microphone is, 0…1, about ten times a second while you talk. |
| `{type: "cancel"}` | The recording was cancelled or heard nothing. The window closes. |
| `{type: "settings"}` | **Plugin settings…** in Settings › Agent was clicked (only with `"settings": true`); nothing is recorded. Show your settings. |

`cadabra.on("*", fn)` gets every event.

Nothing is sent anywhere on `final`: it is up to the page what happens next. The example shows the
words, lets you edit them, and sends them when you press Return.

## What the page can ask for

| Call | Does |
|---|---|
| `cadabra.close()` | Closes the window. |
| `cadabra.resize(width, height)` | Resizes it (120–900 by 60–900 points), staying near the text. |
| `cadabra.copy(text)` | Puts text on the clipboard. |
| `cadabra.storage.get(key)` | A value the plugin saved before (a promise). |
| `cadabra.storage.set(key, value)` | Saves a JSON value for this plugin; `null` removes it. |

Storage is per plugin, in `~/Library/Application Support/Cadabra/PluginData/<id>.json`, readable only
by you. It is where a token goes: ask for it in the page and keep it there.

Settings belong to the page: keep them in `cadabra.storage`, and show them when you're told `settings`
(Settings › Agent › **Plugin settings…**, with `"settings": true`) and wherever else you like, such as a
⚙︎ in the window.

## Talking to the agent

The page calls its agent itself, with `fetch` (streaming with `response.body.getReader()` works), or a
WebSocket. Agents don't need CORS headers. Audio can play without a click.

## What the page can't do

- It is loaded from its folder and may read only files in that folder.
- Every request to anywhere other than its `hosts` is blocked (`http`, `https`, `ws`, `wss`), including
  scripts, fonts and images from the web: bring them along in the folder.
- It knows nothing but what it is told above: not the app you were in, not the text there, not your
  dictation history or vocabulary.

## A suggested agent API

The example agent and plugin use this; nothing in Cadabra depends on it.

- `POST /text {"text": "…"}` answers `{"reply": "…", "conversation_id": "…"}`. Sending the id back in
  `X-Conversation-Id` continues the conversation.
- With `Accept: application/x-ndjson` the answer may come as one JSON object per line, so the agent can
  say what it is doing: `{"type": "activity", "state": "thinking"}` while it works, then
  `{"type": "result", "reply": "…"}` or `{"type": "error", "error": "…"}`.
- `POST /speech {"text", "language"}` answers a WAV of the text.
- A token, if any, goes in `Authorization: Bearer …`.
