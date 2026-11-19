"""CTC prefix beam search with hotword biasing, on the app's training recordings.

SenseVoice's own decoding takes the best token of every frame. Here a few prefixes are kept per frame,
and a prefix that spells one of the user's words (their vocabulary and the words they corrected to)
gets a bonus per token, taken back if the word isn't finished. A word the model barely heard can't
win; one it was torn about (不许 or push?) can.

    python hotwords.py                  # vocabulary and learned words, a few bonuses
    python hotwords.py --vocabulary     # only the vocabulary the user typed in Settings
"""
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from knn_ctc import cer, normalize
from sensevoice import BLANK, MODEL_DIR, SenseVoice, load_wav

SUPPORT = Path.home() / "Library/Application Support/Cadabra"


class Trie:
    def __init__(self):
        self.next: dict[int, "Trie"] = {}
        self.end = False
        self.depth = 0

    def add(self, ids):
        node = self
        for i in ids:
            child = node.next.get(i)
            if child is None:
                child = node.next[i] = Trie()
                child.depth = node.depth + 1
            node = child
        node.end = True


def hotword_trie(sv: SenseVoice, words) -> Trie:
    root = Trie()
    for w in words:
        for form in {w, w.lower()}:
            ids = sv.tokenize(form)
            if ids:
                root.add(ids)
    return root


def step(root: Trie, node: Trie, pending: float, token: int, bonus: float, partial: float = 1.0):
    """Context state after `token`: (node, pending bonus, score change). The bonus of a word in progress
    is pending: taken back if the word breaks off, kept once it is finished."""
    change = 0.0
    if token not in node.next:
        change, pending = -pending, 0.0   # the partial word broke off
        node = root
        if token not in root.next:
            return root, 0.0, change
    child = node.next[token]
    if child.end:
        # Finished: the word's whole bonus, kept. A longer word may still go on from here.
        return (child if child.next else root), 0.0, change + bonus * child.depth - pending
    # On the way: part of the bonus, so a word that has only begun can't push the alternatives out.
    return child, pending + bonus * partial, change + bonus * partial


def decode(logp: np.ndarray, root: Trie, bonus: float, beam: int = 8, top: int = 6, partial: float = 1.0):
    """Prefix beam search. Beams: prefix -> [log p ending in blank, log p ending in a token, node, pending, context score]."""
    NEG = -1e30
    beams = {(): [0.0, NEG, root, 0.0, 0.0]}
    for t in range(len(logp)):
        lp = logp[t]
        cand = set(np.argpartition(-lp, top)[:top].tolist())
        if bonus:
            for _, _, node, _, _ in beams.values():
                cand.update(node.next)
                cand.update(root.next)
        cand.discard(BLANK)
        nxt = defaultdict(lambda: [NEG, NEG, None, 0.0, 0.0])
        for prefix, (pb, pnb, node, pending, ctx) in beams.items():
            total = np.logaddexp(pb, pnb)
            e = nxt[prefix]
            e[0] = np.logaddexp(e[0], total + lp[BLANK])
            e[2], e[3], e[4] = node, pending, ctx
            last = prefix[-1] if prefix else None
            for c in cand:
                p = lp[c]
                if p < -12 and c not in node.next and c not in root.next:
                    continue
                if c == last:
                    e[1] = np.logaddexp(e[1], pnb + p)   # the same token continuing
                    new = prefix + (c,)
                    f = nxt[new]
                    if f[2] is None:
                        f[2], f[3], d = step(root, node, pending, c, bonus, partial)
                        f[4] = ctx + d
                    f[1] = np.logaddexp(f[1], pb + p)
                else:
                    new = prefix + (c,)
                    f = nxt[new]
                    if f[2] is None:
                        f[2], f[3], d = step(root, node, pending, c, bonus, partial)
                        f[4] = ctx + d
                    f[1] = np.logaddexp(f[1], total + p)
        beams = dict(sorted(nxt.items(), key=lambda kv: -(np.logaddexp(kv[1][0], kv[1][1]) + kv[1][4]))[:beam])
    # An unfinished word gives its bonus back.
    best = max(beams.items(), key=lambda kv: np.logaddexp(kv[1][0], kv[1][1]) + kv[1][4] - kv[1][3])
    return list(best[0]), best[1][4] - best[1][3] > 0


def biased(logp, root, bonus, beam=16, partial=0.6, greedy=None):
    """The beam's answer if it spells at least one hotword; otherwise plain greedy decoding, so the beam
    search alone never changes anything."""
    ids, used = decode(logp, root, bonus, beam=beam, partial=partial)
    return ids if used else greedy


def main():
    sv = SenseVoice()
    vocabulary = subprocess.run(["defaults", "read", "com.peihongguo.Cadabra", "vocabulary"], capture_output=True, text=True).stdout.strip()
    words = {w.strip() for w in re.split(r"[,，、;；\n]", vocabulary) if w.strip()}
    if "--vocabulary" not in sys.argv:
        for f in json.loads((SUPPORT / "learned.json").read_text()):
            meant = f["meant"]
            # English only: a learned Chinese word is usually an everyday one (这边), and a bonus for it
            # changes other everyday words.
            for w in re.findall(r"[A-Za-z][A-Za-z0-9-]+", meant):
                words.add(w)
    # Too short to be worth a bonus: it would match everywhere.
    words = {w for w in words if (w.isascii() and len(w) >= 3) or (not w.isascii() and len(w) >= 2)}
    print(f"{len(words)} hotwords")
    root = hotword_trie(sv, words)

    data = []
    for s in json.loads((SUPPORT / "Training/samples.json").read_text()):
        if s["label"] == "modelChanged":
            continue
        logp, _ = sv.run(load_wav(SUPPORT / "Training" / s["audio"]))
        data.append(dict(logp=logp, ref=s["text"], base=sv.text(sv.greedy(logp)), label=s["label"]))
    others = [sv.run(load_wav(p))[0] for p in sorted((MODEL_DIR / "test_wavs").glob("*.wav"))]
    total = sum(len(normalize(d["ref"])) for d in data)
    targets = [(i, w) for i, d in enumerate(data) for w in words if w.lower() in d["ref"].lower()]

    def report(name, outs):
        err = sum(cer(o, d["ref"])[0] for o, d in zip(outs, data))
        worse = sum(cer(o, d["ref"])[0] > cer(d["base"], d["ref"])[0] for o, d in zip(outs, data))
        better = sum(cer(o, d["ref"])[0] < cer(d["base"], d["ref"])[0] for o, d in zip(outs, data))
        right = sum(w.lower() in outs[i].lower() for i, w in targets)
        print(f"{name:30s} CER {err / total:.3%}  words right {right}/{len(targets)}  better {better}  worse {worse}")
        return err

    report("greedy (now)", [d["base"] for d in data])
    best = None
    configs = [(b, 0.6, 16) for b in (2.5, 3.0, 3.5)]
    for bonus, partial, beam in configs:
        outs = [sv.text(biased(d["logp"], root, bonus, beam, partial, sv.greedy(d["logp"]))) for d in data]
        err = report(f"bonus {bonus} part {partial} beam {beam}", outs)
        changed = sum(sv.text(sv.greedy(lp)) != sv.text(biased(lp, root, bonus, beam, partial, sv.greedy(lp))) for lp in others)
        print(f"{'':30s} other speakers changed {changed}/{len(others)}")
        if best is None or err < best[0]:
            best = (err, (bonus, partial, beam), outs)
    _, bonus, outs = best[0], best[1], best[2]
    print(f"\nchanges at bonus {bonus}:")
    for d, o in zip(data, outs):
        if o != d["base"]:
            print(f"  base: {d['base']}\n  beam: {o}\n  ref : {d['ref']}\n")


if __name__ == "__main__":
    main()
