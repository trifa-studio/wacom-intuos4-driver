# PTK-540WL USB Protocol (verified on hardware, macOS 26 arm64)

Unit under test enumerates as **VID 0x056A / PID 0x00BC** ("Intuos4 WL" wired per
linuxwacom `wacom_features_0xBC`: 40640×25400 units, 2048 pressure levels).
Older firmware may enumerate as 0x00B9 — match both.

## Mode switch (feature report)

| Command | Buffer | Effect |
|---|---|---|
| Digitizer mode | SET feature id `0x02`, bytes `[02 02 02]` | Streams 10-byte pen frames on report `0x02`; mouse reports stop |
| Mouse mode | SET feature id `0x02`, bytes `[02 01]` | Restores generic HID mouse (readback confirms value byte) |
| Read config | GET feature `0x02` → `[02 v]` | `v=0x02` digitizer, `v=0x01` mouse |

IOKit counts the report-ID byte inside the buffer length.

**Mode persists across unplug; only a power cycle resets it.** Always restore
mouse mode before closing the device, or the cursor dies until power-cycle.
Never SIGKILL/SIGTERM a seized open without closing it first.

## Pen frames — report ID 0x02, 10 bytes total

Same grammar as linuxwacom `wacom_intuos_irq` with data[0]=0x02:

```
data[1] flags:
  (d1 & 0xfc) == 0xc0        tool-enter packet
      toolID = (d2<<4)|(d3>>4)|((d7&0xf)<<20)|((d8&0xf0)<<12)
      serial = ((d3&0xf)<<28)|(d4<<20)|(d5<<12)|(d6<<4)|(d7>>4)
      observed: c2 80 20 58 00 b6 d1 00 00 → toolID 0x100802 (General Pen)
  (d1 & 0xfe) == 0x80 && rest==0   out-of-proximity
  (d1 & 0xb8) == 0xa0        general pen packet:
      X = (d2<<9)|(d3<<1)|((d9>>1)&1)
      Y = (d4<<9)|(d5<<1)|(d9&1)
      pressure = ((d6<<2)|((d7>>6)&3))<<1 | (d1&1)     // 0..2047
      tiltX = (((d7<<1)&0x7e)|(d8>>7)) - 64            // -64..63
      tiltY = (d8&0x7f) - 64
      barrel1 = d1&2, barrel2 = d1&4, tipDown = pressure>10
  distance = (d9>>2)&0x3f
```

## Pad — report ID 0x0C, 10 bytes (INTUOS4 layout)

```
ring:    d1&0x80 touched, position d1&0x7f (0..71)
center:  d2&0x01
keys1-6: d3 bits 0..5 ; keys7-8: d3 bits 6..7
```

## Event injection notes (macOS 26)

- Post mouse events with `.mouseEventSubtype = tabletPoint` AND set BOTH
  `.mouseEventPressure` and `.tabletEventPointPressure` (AppKit apps read the
  former, Adobe reads the latter). Verified working in AppKit test canvas.
- Post `.tabletProximity` enter/leave paired with same pointer/device IDs.
- Stretch mapping (`preserveAspectRatio=false`) avoids dead margins at edges.
