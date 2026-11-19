# Manual checks

`swift test` covers the logic: learning from edits, the checks around the correction model, the
waveform's pace, resampling, the clipboard swap, the stores. What it can't reach needs a person and a
real Mac. Run through this list before a release, and after changing the file named.

## Hotkey (HotkeyMonitor, AppModel)

- [ ] Hold the dictation key, speak, release: the text appears at the cursor.
- [ ] Toggle mode (Settings): press once to start, again to finish.
- [ ] Holding the key and pressing another (⌥A, ⌥-click) types the shortcut and doesn't dictate.
- [ ] Talking for a few seconds with the key held, then clicking somewhere: the recording goes on.
- [ ] esc while the HUD says it is recognizing: nothing is pasted, the HUD says cancelled.
- [ ] In Vim's insert mode, start dictating and press esc: the recording is cancelled and Vim is
      still in insert mode. In a browser dialog, the dialog stays open.
- [ ] Not recording, esc reaches the app as usual.

## Microphones (Microphones, AudioRecorder)

- [ ] `Cadabra --microphones` lists the inputs and marks the one Automatic picks.
- [ ] With AirPods connected and Automatic: recording starts at once (`--record 3 out.wav` prints
      "opened in" well under a second) and music in the AirPods doesn't turn muffled.
- [ ] AirPods picked explicitly: it records from them (after the switch to call mode).
- [ ] The picked microphone unplugged: it records from another one.
- [ ] The waveform moves about ten bars a second and follows your voice.

## Pasting (TextInjector, ClipboardSwap)

- [ ] TextEdit, an Electron app (Slack, VS Code), Terminal: the text arrives once, complete.
- [ ] With "restore clipboard" on, what you had copied is back a moment later; also after two
      dictations in quick succession.
- [ ] Accessibility turned off: the text is copied instead, and the HUD says so.
- [ ] Stop dictating, switch to another app before the text arrives: it is copied, not pasted there.
- [ ] Focus in a password field (a login sheet, `sudo` in Terminal): nothing is pasted.
- [ ] Dictating with no text field focused: the dictation stays on the clipboard.

## Learning from edits (EditWatcher, LearnedFixes, TrainingData)

- [ ] Dictate into TextEdit, fix one misheard word within two minutes, click elsewhere: Settings ›
      Vocabulary shows it, and the training sample count includes an edited one.
- [ ] Type more after the dictation without fixing anything: nothing is learned.
- [ ] Rewrite a word into one that sounds nothing like it: nothing is learned.
- [ ] Fix the same word twice: the next dictation has it right before correction.

## Hotwords and context (HotwordDecoder, FocusContext)

- [ ] `Cadabra --transcribe a.wav` and `CADABRA_ASR=sherpa Cadabra --transcribe a.wav` agree on most
      recordings; `--hotwords "push, commit"` gets those words where the model was unsure.
- [ ] Dictating a name that appears just before the cursor (in TextEdit) writes it that way.

## Rewrite by voice (AppModel, Corrector.rewrite)

- [ ] Select a sentence in TextEdit, hold right ⌘, say "翻译成英文": the selection is replaced.
- [ ] In an Electron app (Slack) the selection is read by copying, and the clipboard comes back.
- [ ] Nothing selected: "写一句感谢的话" writes at the cursor.
- [ ] esc while the HUD says it is rewriting: nothing is pasted.

## Correction model (Corrector)

- [ ] Download starts, shows progress, can be cancelled.
- [ ] Switching to the other model mid-download cancels it and shows the new model's state.
- [ ] Unused for 15 minutes, Settings says the model was unloaded; the next recording loads it
      again, and that dictation comes out uncorrected rather than late.
- [ ] With correction on, the menu says the model is ready; a dictation with a learned term comes
      out corrected. `CADABRA_LLM_TESTS=1 swift test` passes.

## Build (build.sh)

- [ ] After `./build.sh install`, Microphone and Accessibility are still granted.
