#!/usr/bin/env bash
# S7 counterfactuals: how far does the pure set grow under small, hypothetical
# edits? Works on a throwaway copy; the repository is never touched.
#
#   docker run --rm -v "$PWD":/src:ro -w /src swift:5.9 \
#     bash docs/research/spikes/s7-linux-compile/whatif.sh models
#   docker run --rm -v "$PWD":/src:ro -w /src swift:5.9 \
#     bash docs/research/spikes/s7-linux-compile/whatif.sh models+combine-stub
#
# Scenarios:
#   models               Models.swift drops `import AVFAudio`; its one use of
#                        AVSpeechUtteranceDefaultSpeechRate becomes the literal 0.5.
#   models+combine-stub  as above, plus every `import Combine` line is removed and a
#                        stub file declares an empty `ObservableObject` protocol and a
#                        trivial `@Published` property wrapper. Files that still fail
#                        use real Combine (publishers, sink, AnyCancellable), not just
#                        the observable-object pattern.
set -eu
SCENARIO=${1:-models}
COPY=$(mktemp -d)
trap 'rm -rf "$COPY"' EXIT
cp Sources/PowerUp/*.swift "$COPY/"

sed -i.bak -e '/^import AVFAudio$/d' \
  -e 's/ttsRate: AVSpeechUtteranceDefaultSpeechRate,/ttsRate: 0.5,/' \
  "$COPY/Models.swift"

if [ "$SCENARIO" = "models+combine-stub" ]; then
  for f in "$COPY"/*.swift; do sed -i.bak -e '/^import Combine$/d' "$f"; done
  cat > "$COPY/ZZCombineStub.swift" <<'SWIFT'
// Counterfactual stub, S7 only. Not a proposal for production code.
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
SWIFT
fi
rm -f "$COPY"/*.bak

echo "scenario: $SCENARIO"
echo "diff of the edited copy against Sources/PowerUp:"
diff -r Sources/PowerUp "$COPY" || true
echo
SRC="$COPY" bash "$(dirname "$0")/typecheck.sh"
