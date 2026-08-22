# USB capture fixtures

JSONL lines written by `intuos-cli --sniff --save Fixtures/usb`:

```json
{"ts":1710000000000,"reportID":2,"hex":"02c0...","len":10}
```

Capture workflow:

```bash
cd IntuosDriver
swift run intuos-cli --sniff --hex --save Fixtures/usb
```

Plug the PTK-540WL over USB, move the pen, press ExpressKeys, rotate the ring, then Ctrl+C.
