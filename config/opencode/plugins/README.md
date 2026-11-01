# OpenCode Plugin Extensions

This directory holds local plugin extensions and event hooks for OpenCode.

## Creating a Plugin
Plugins are TypeScript or JavaScript modules that export a function matching `@opencode-ai/plugin`:

```ts
import type { Plugin } from "@opencode-ai/plugin";

export default (async ({ client, project, directory, $ }) => {
  return {
    "tool.execute.before": async (input, output) => {
      // Intercept or modify tool arguments before execution
    },
    "tool.execute.after": async (input, output) => {
      // Process tool results after completion
    }
  };
}) satisfies Plugin;
```

Any `*.ts` or `*.js` file placed in this directory is auto-discovered by OpenCode.
