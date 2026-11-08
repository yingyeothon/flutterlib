#!/usr/bin/env bash
# The green gate. pre-push runs exactly this, in this order, so a failure here is the
# failure a push would hit. CI (.github/workflows/ci.yml) runs the same steps plus,
# in the example, a `flutter create` clean-tree check with `flutter build linux
# --debug`, and the same for web with `flutter build web`.
#
#   SKIP_EXAMPLE_GATE=1 tool/gate.sh   skips the Flutter packages and example on a machine without flutter.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

tool/install-git-hooks.sh >/dev/null

step() { printf '\n== %s\n' "$*"; }

step "dart pub get"
dart pub get

step "dart format"
dart format --output=none --set-exit-if-changed packages tool examples

# Flutter packages (rules/tooling.md) resolve on their own and are analyzed
# and tested by flutter in the last step; the Dart steps take the rest.
mapfile -t dart_packages < <(dart run tool/bin/list_packages.dart)
mapfile -t flutter_packages < <(dart run tool/bin/list_packages.dart --flutter)
# A failed or empty listing must not shrink the gate to tool/ alone.
[ "${#dart_packages[@]}" -gt 0 ] || { echo "gate: list_packages printed no Dart package" >&2; exit 1; }

step "dart analyze"
dart analyze --fatal-infos "${dart_packages[@]}" tool

# `dart test` at the workspace root finds no test/ of its own and stops; each
# member runs its suite from its own directory.
step "dart test"
for member in "${dart_packages[@]}" tool/; do
  [ -d "$member/test" ] || continue
  ( cd "$member" && dart test --reporter=compact )
done

step "coverage floor"
dart run tool/bin/check_coverage.dart

step "docs"
dart run tool/bin/check_docs.dart

if [ -n "${SKIP_EXAMPLE_GATE:-}" ]; then
  echo "gate: SKIP_EXAMPLE_GATE set, skipping the Flutter example"
else
  step "flutter packages and example"
  command -v flutter >/dev/null || { echo "gate: flutter is not on PATH; set SKIP_EXAMPLE_GATE=1 to skip the example (CI never does)" >&2; exit 1; }
  for package in "${flutter_packages[@]}"; do
    ( cd "$package" && flutter pub get && flutter analyze --fatal-infos && flutter test )
  done
  dart run tool/bin/check_coverage.dart --flutter
  for example in examples/*/; do
    [ -f "$example/pubspec.yaml" ] || continue
    ( cd "$example" && flutter pub get && flutter analyze --fatal-infos && flutter test )
  done
fi

echo
echo "gate: green"
