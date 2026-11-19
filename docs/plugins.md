# Look plugins for the agent panel

The agent key (Settings › Agent) opens a small panel: it shows the words while you talk, waits for
Return, and shows the agent's answer. A **look plugin** draws at the top of that panel, so an agent
can come with its own look (a face, a voice wave) without being part of Cadabra.

## A plugin is a folder

```
~/Library/Application Support/Cadabra/Plugins/<id>/
  plugin.json
  index.html        (and whatever it loads: scripts, images, fonts)
```

`plugin.json`:

```json
{
  "name": "Echo",
  "entry": "index.html",
  "height": 140,
  "background": "#0b141c",
  "foreground": "#e6f1f5"
}
```

| Key | Meaning |
|---|---|
| `name` | Shown in Settings › Agent › Look. |
| `entry` | The page, inside the folder (default `index.html`). |
| `height` | Points it takes at the top of the panel, 40–400 (default 120). The panel is 440 points wide. |
| `background`, `foreground` | Optional `#rrggbb` colours for the whole panel, so it looks of a piece with the plugin. |

Pick it in Settings › Agent › Look; **Open the plugins folder** takes you there.

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

## What the page can't do

- It is loaded from its folder and may read only files in that folder.
- Every network request (`http`, `https`, `ws`, `wss`) is blocked.
- It gets the events above and nothing else: not the words, not the reply, not the agent's address.

## Where `activity` comes from

Cadabra asks the agent for a streamed answer (`Accept: application/x-ndjson`). An agent that streams
sends one JSON object per line: `{"type": "activity", "state": "thinking"}` while it works, then
`{"type": "result", "reply": "…"}` (or `{"type": "error", "error": "…"}`). One that doesn't simply
answers `{"reply": "…"}`, and `activity` stays null.
