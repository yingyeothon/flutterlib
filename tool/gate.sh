#!/usr/bin/env bash
# The green gate. pre-push runs exactly this, in this order, so a failure here is the
# failure a push would hit. CI (.github/workflows/ci.yml) runs the same steps plus a
# `flutter create` clean-tree check and `flutter build linux --debug`.
#
#   SKIP_EXAMPLE_GATE=1 tool/gate.sh   skips the Flutter example on a machine without flutter.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

tool/install-git-hooks.sh >/dev/null

step() { printf '\n== %s\n' "$*"; }

step "dart pub get"
dart pub get

step "dart format"
dart format --output=none --set-exit-if-changed packages tool examples

step "dart analyze"
dart analyze --fatal-infos packages tool

# `dart test` at the workspace root finds no test/ of its own and stops; each
# member runs its suite from its own directory.
step "dart test"
for member in packages/*/ tool/; do
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
  step "flutter example"
  command -v flutter >/dev/null || { echo "gate: flutter is not on PATH; set SKIP_EXAMPLE_GATE=1 to skip the example (CI never does)" >&2; exit 1; }
  for example in examples/*/; do
    [ -f "$example/pubspec.yaml" ] || continue
    ( cd "$example" && flutter pub get && flutter analyze --fatal-infos && flutter test )
  done
fi

echo
echo "gate: green"
