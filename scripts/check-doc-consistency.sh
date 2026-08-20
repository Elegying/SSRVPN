#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

all_docs=()
current_docs=()
while IFS= read -r document; do
  all_docs+=("$document")
  if [[ "$document" != "CHANGELOG.md" ]]; then
    current_docs+=("$document")
  fi
done < <(
  git -C "$ROOT" -c core.quotepath=false ls-files '*.md' '*.MD' |
    LC_ALL=C sort
)

if [[ "${#all_docs[@]}" -eq 0 ]]; then
  echo "No tracked Markdown documents found" >&2
  exit 1
fi

python3 "$ROOT/scripts/check_doc_consistency.py" --self-test
python3 "$ROOT/scripts/check_doc_consistency.py" --links-only "$ROOT" "${all_docs[@]}"
python3 "$ROOT/scripts/check_doc_consistency.py" "$ROOT" "${current_docs[@]}"
