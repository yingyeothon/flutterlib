# Rules index

Open the file whose trigger matches the task. Each file is short; read it whole.

| File | Open it when |
| --- | --- |
| [architecture.md](architecture.md) | adding or changing a package, a public type, a wire frame, the state machine, a transport seam |
| [flutter.md](flutter.md) | anything a Flutter app or platform touches: web, background, lifecycle, `kDebugMode`, the example |
| [workflow.md](workflow.md) | starting or finishing any task: branch policy, the completion ritual, the review, the green gate |
| [testing.md](testing.md) | writing or changing tests, doubles, coverage, the integration tag |
| [manual-verification.md](manual-verification.md) | proving a change in a running build: the offline demo, the debug hooks, a real gateway |
| [security.md](security.md) | the token, logging, the guards, hostnames, what this public repo may name |
| [tooling.md](tooling.md) | the gate, the workspace, coverage and docs scripts, Dart or Flutter tool gotchas |
| [documentation.md](documentation.md) | README, `docs/`, doc comments, mermaid, examples |
| [release.md](release.md) | versioning, tagging, install snippets |
| [deployment.md](deployment.md) | deciding whether and how a change ships: the deployment decision flow |

## Maintenance

- After each completed task, fold durable lessons into the matching file above and add
  a row here when a file is added or removed.
- A lesson is durable when a future agent with no memory of this session would repeat
  the mistake without it. Session notes go to `.claude/` (git-ignored except the
  tracked `settings.json`), not here.
- Rules point at canonical documents (`CONVENTIONS.md`, the gateway README); they do not
  copy them.
