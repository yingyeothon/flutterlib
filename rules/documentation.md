# Documentation

## Ownership: one fact, one owner

| Layer | Owns | Gated by |
| --- | --- | --- |
| `docs/` (indexed by `docs/README.md`) | the consumer's flow: getting started, auth, lobby, dungeon, key-value store, lifecycle, errors, Flutter, troubleshooting | `check_docs` 1, 2, 6 (the `40xx` codes only), 7 |
| `packages/<name>/README.md` | that package's purpose, install snippet, usage, `## Public API`, differences from the originals | `check_docs` 3, 5 |
| root `README.md` | what the library is, the package table, the dependency graph | `check_docs` 3, 4 |
| `///` doc comments | what a consumer needs at the call site | `dart analyze` (`public_member_api_docs` is an error) |
| `CONVENTIONS.md`, `rules/` | how the code is designed and how work is done | reviewers |
| the `service` repo | the wire protocol, the auth endpoints, the console | not ours |

A fact appears once. `docs/` links to a package README for a signature; a package
README links to `docs/` for a flow; neither copies the gateway README — they cite it.

## Package README shape

1. `# yingyeothon_<name>` — exactly, first line.
2. One paragraph: what it is for, and the one sentence a `pub.dev` visitor needs
   (pub.dev does not render mermaid, so the paragraph stands alone).
3. **Exactly one mermaid diagram**, above `## Install`, with a one-line lead-in.
4. `## Install` — the `pubspec.yaml` git-dependency snippet naming the package.
5. `## Usage` — the shortest complete program.
6. Package-specific sections.
7. `## Public API` — every name in the barrel's `show` lists, in backticks, grouped.
8. `## Differences from @yingyeothon/<name> and Yingyeothon.<Name>` — deliberate
   departures from tslib and csharplib, each with a reason.

A changed export updates the barrel, the `///` comment and `## Public API` in the same
commit; `check_docs` fails otherwise.

## `docs/` page shape

- Start with what the reader is doing, not with the package. A page is one task.
- `## 1.` … numbering only on `getting-started.md`.
- Prose at 88 columns, hard-wrapped. Bold marks a **trap**, not emphasis.
- A number next to the option that sets it (`helloTimeoutMs`, 10 000 ms), once.
- Tables for refusals, close codes and options carry a "why you would hit this"
  column.
- The `import` line appears once per page, in the first snippet.
- `troubleshooting.md` is symptom → one check → link; no diagrams.

## Mermaid

- At most one diagram per H2 section; ≤ 12 nodes in a flowchart; `graph LR` for
  structure, `sequenceDiagram` for a handshake or a flow, `stateDiagram-v2` for the
  connection states, `flowchart TD` for a decision.
- No `style`, `classDef`, `linkStyle` or `fill:`; the viewer's theme decides colours.
- No node named `end` (case-insensitive) — it breaks the parser.
- Quote a label that contains `(`, `)`, `:`, `,`, `{`, `}`, `;` or `#`. Only `<br/>`
  as markup.
- Every diagram has a lead-in sentence and shows a mechanism, not a table of contents.
  A README and a guide page draw different diagrams for the same package.
- `check_docs` lints these mechanically but cannot parse; render a new diagram once.

## Examples

- `examples/README.md` links every example; each is `publish_to: none`, named without
  the `yingyeothon_` prefix, outside the workspace.
- An example runs with zero infrastructure by default (the offline demo) and takes real
  values through `--dart-define=YYT_*`. It never persists a token.
- Links run one way: `docs/` → `examples/`, examples → package READMEs.

## Language

- Repository content is English; `check_docs` refuses Korean outside a code span.
  Conversation with the user is Korean (`workflow.md`).
- No tracking documents in the repo root. Session notes live in `.claude/`, which is
  git-ignored except for the tracked `.claude/settings.json`.
