# View domains

SwiftUI and AppKit presentation files are grouped by the product area that
owns their behavior under `Sources/PersonalSitePublisherMac/Views`:

- `Editor`: drafts, Markdown editing, composition, and editor overlays
- `AIChat`: chat cards, model switching, tool runs, and diff previews
- `RSS`: subscriptions, article lists, reading, and translation controls
- `Knowledge`: library navigation, import, metadata, backlinks, and notes
- `Settings`: preferences, privacy, tokens, providers, and maintenance options
- `Repository`: repository workspaces, source inspection, and local previews
- `Publishing`: publish drawer and release history
- `Site`: site maintenance, content health, migration, and starter flows
- `Images`: image workbench and repository asset browsing
- `Workspace`: app shell, navigation, task center, and inspectors
- `Shared`: cross-domain visual primitives and design-system support

SwiftPM discovers Swift sources recursively, so adding a view to one of these
directories does not change its module visibility. Keep new view files out of
the `Views` root and update path-sensitive tooling when a file changes domain.
