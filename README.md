# bench-instruments

Three SCPI instruments on one screen, the supply asked for a voltage, the bench limit clamping it.

Article: [instrument-without-an-api](https://makemind.dev/en/build/instrument-without-an-api)

## What is here

- `bench_server/` — Dart MCP server (`mcp_server` from pub.dev). It holds the data and the tools and serves the app's pages as `ui://` resources.
- `bench.mbd/` — the app as a folder of JSON: `manifest.json` and the pages under `ui/`. No build step.
- `instruments/` — C program standing in for the hardware, built by `verify.sh`.
- `captures/` — screenshots taken from AppPlayer by `verify.py`.
- `verify.py`, `verify.sh` — the check.

## Open it in AppPlayer

Add a server app with command `dart`, arguments `run bin/server.dart`, working directory `bench_server/`. The server serves its pages; the player draws them.

## Verify

```bash
bash verify.sh
```

Needs AppPlayer with the debug MCP on (see `tools/README.md`). The script builds what needs building, drives the player through the screens above, asserts the claim at the top of this file, and writes `captures/`.
