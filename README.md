# Token Monitor

A small local menu-bar app for tracking Codex usage from local session logs.

Open `index.html` in a browser to use it. Entries are stored in the browser with `localStorage`.

## macOS app

Build the desktop app:

```bash
./mac/build-mac-app.sh
```

Open `TokenMonitor.app` to run it as a Mac menu-bar app.

Codex usage is read locally from:

```text
~/.codex/sessions/**/*.jsonl
```

No network call is required for Codex usage.

Claude sync uses the Anthropic usage API with an Admin/API key. It does not read private Claude.ai or Claude Desktop login sessions.

The refresh button can also read Claude Desktop's visible Usage screen through macOS Accessibility. Open Claude Settings > Usage first, then grant TokenMonitor Accessibility permission when macOS prompts.

## Upgrading to a new version

1. Pull the latest code:

```bash
git pull
```

2. Rebuild the macOS app:

```bash
./mac/build-mac-app.sh
```

3. Quit the old TokenMonitor from the menu bar, then open the new `TokenMonitor.app`.
