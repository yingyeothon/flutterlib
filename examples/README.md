# Examples

Each example is a Flutter app that depends on the packages by path, stays outside the
pub workspace, and runs with **no credential and no network** by default. Platform
folders are not committed: inject the ones you need with `flutter create .` and the
app builds.

| Example | What it shows |
| --- | --- |
| [playground](playground/) | sign-in, lobby (zone map, chat, parties), dungeon `q`, reconnect banners, the key-value store's two cases, and an offline demo against the in-process fake gateway |

```bash
cd examples/playground
flutter create . --platforms=linux --project-name yyt_playground --org life.yyt
flutter run -d linux
```

Then **Offline demo**. Real values go in through `--dart-define=YYT_*`; see the
example's [README](playground/README.md).
