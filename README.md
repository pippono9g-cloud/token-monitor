# Token Monitor

A small local app for manually tracking token usage and estimated cost.

Open `index.html` in a browser to use it. Entries are stored in the browser with `localStorage`.

## macOS app

Build the desktop app:

```bash
./mac/build-mac-app.sh
```

Open `dist/TokenMonitor.app` to run it as a Mac app window.

Claude sync uses the Anthropic usage API with an Admin/API key. It does not read private Claude.ai or Claude Desktop login sessions.

The refresh button can also read Claude Desktop's visible Usage screen through macOS Accessibility. Open Claude Settings > Usage first, then grant TokenMonitor Accessibility permission when macOS prompts.
