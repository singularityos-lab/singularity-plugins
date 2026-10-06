# Singularity Plugins

> [!IMPORTANT]
> Report bugs and request features in the
> [Singularity Desktop tracker](https://github.com/singularityos-lab/singularity-desktop/issues/new/choose).

libpeas plugins for the Singularity Desktop shell (tray icons, clipboard
history, media controls, weather, workspaces indicator, docks and more).

Each plugin builds a shared module installed under
`lib/singularity/plugins/<name>/`.

## Deprecated plugins

- `clipboard-history` is deprecated. The desktop now keeps the clipboard
  history itself: press Super+V, or open Settings, Clipboard, to search, pin
  and paste entries. The plugin is still built and loadable for now, but it is
  hidden from Settings, Plugins, and the desktop removes it from
  `enabled-plugins` once, turning on the built-in history for users who had it
  enabled. The plugin kept its entries in memory only, so there is no stored
  history or pinned item to carry over. It will be removed in a later release.

## Requirements

- GTK4, libgee-0.8, libpeas-2
- [libsingularity](https://github.com/singularityos-lab/libsingularity)

## License

GPL-3.0-only - see [LICENSE](LICENSE).

## Use of Generative AI

Maintainers may use generative AI tools as assistants while working on singularity-plugins. Non-trivial assisted commits disclose the tool, model, and scope of the work.

AI tools may assist with code comments, documentation, repetitive code, and issue triage. Maintainers make project decisions and review every assisted change before it is merged.

Use these trailers for non-trivial assisted commits:

```plain
Assisted-by: <tool>:<model-version>
AI-Scope: <what the tool generated and the prompt or a short prompt summary>
```

Single-line completions, renames, and formatting changes do not need trailers.

Coding agents must also follow [AGENTS.md](AGENTS.md) before changing files,
creating commits, or opening pull requests.
