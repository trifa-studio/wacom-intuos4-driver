# Modifier regression fixture

`photoshop-option-release.jsonl` preserves keyboard/pen event ordering and flags
from the marked 2026-10-16 Photoshop sampling failure. Only event type, modifier
flags, modifier/Tab keycode and pen button mask are retained. Absolute times,
process IDs, application names, coordinates and document information are omitted.

The pointer runner replays physical modifier transitions and pen input. The
fixture contains two Option releases followed by 23 stale Option-modified pen
events in total. New output must follow the released keyboard state instead.
