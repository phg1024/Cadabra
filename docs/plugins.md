# Agent plugins

The agent key (Settings › Agent) talks to an agent: you hold the key and speak, the words show in a
small panel, Return sends them, and the agent's answer shows in the same panel. Cadabra knows no agent
by itself: each one comes as a **plugin** that says how to talk to it and may bring its own **look**
(a face, a voice wave) for the top of the panel.

A working example to try or start from is in [`examples/echo-agent`](../examples/echo-agent): a tiny
agent that says back what it heard, and its plugin.

## A plugin is a folder

```
~/Library/Application Support/Cadabra/Plugins/<id>/
  plugin.json
  index.html        (optional: the look, and whatever it loads)
```

`plugin.json`:

```json
{
  "name": "Echo",
  "agent": {
    "address": "http://localhost:8787",
    "ask": "/text",
    "text_field": "text",
    "reply_field": "reply",
    "conversation": { "header": "X-Conversation-Id", "field": "conversation_id" },
    "stream": "ndjson",
    "speech": "/speech",
    "health": "/health",
    "token": "bearer"
  },
  "look": {
    "entry": "index.html",
    "height": 130,
    "background": "#0b141c",
    "foreground": "#e6f1f5"
  }
}
```

### `agent` (required): how to talk to it

| Key | Meaning | Default |
|---|---|---|
| `address` | Where it is; the user can set another in Settings. | (none) |
| `ask` | `POST` here with `{"<text_field>": "<the words>"}`. | `/text` |
| `text_field`, `reply_field` | The field the words go in, and the one the reply comes back in. | `text`, `reply` |
| `conversation` | A follow-up within five minutes sends the last answer's `field` back in `header`, to continue the conversation. `null`: no conversations. | `X-Conversation-Id`, `conversation_id` |
| `stream` | `"ndjson"`: the answer may come as newline-delimited JSON, so the agent can say what it is doing on the way (see below). | off |
| `speech` | `POST {"text", "language"}` here for a WAV of the reply; offers **Read replies aloud**. | none |
| `health` | `GET` here for **Test connection**. | none |
| `token` | `"bearer"`: the token from Settings goes in `Authorization: Bearer …`; `"none"`: no token. | `bearer` |

A failed request may answer `{"error": "…"}`; Cadabra shows that text.

### `look` (optional): its face

| Key | Meaning |
|---|---|
| `entry` | The page, inside the folder (default `index.html`). |
| `height` | Points it takes at the top of the panel, 40–400 (default 120). The panel is 440 points wide. |
| `background`, `foreground` | Optional `#rrggbb` colours for the whole panel, so it looks of a piece with the plugin. |

Pick the plugin in Settings › Agent; **Open the plugins folder** takes you there.

## What the page is told

While the panel is on screen, Cadabra calls this 20 times a second:

```js
window.cadabra.update({
  phase: "listening",   // listening | confirm | waiting | reply | failed
  activity: null,       // what the agent says it is doing while it answers, e.g. "thinking",
                        // "researching", "calculating", "coding"; null otherwise
  speaking: false,      // the reply is being read aloud
  level: 0.42           // 0…1: the microphone while listening, the voice while speaking, else 0
})
```

Define `window.cadabra = { update(event) { … } }` and animate as you like (`requestAnimationFrame`).
The page's background is transparent; paint your own if you want one.

## What the look can't do

- It is loaded from its folder and may read only files in that folder.
- Every network request (`http`, `https`, `ws`, `wss`) is blocked.
- It gets the events above and nothing else: not the words, not the reply, not the agent's address.

## Where `activity` comes from

With `"stream": "ndjson"` Cadabra asks for a streamed answer (`Accept: application/x-ndjson`). An agent
that streams sends one JSON object per line: `{"type": "activity", "state": "thinking"}` while it
works, then `{"type": "result", "reply": "…"}` (or `{"type": "error", "error": "…"}`). One that answers
with plain JSON works too; `activity` then stays null.
