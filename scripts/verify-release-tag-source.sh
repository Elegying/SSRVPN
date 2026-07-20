#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 refs/tags/<version>" >&2
  exit 64
fi

tag_ref="$1"
if [[ "$tag_ref" != refs/tags/* ]]; then
  echo "::error::Release source is not a tag ref: $tag_ref" >&2
  exit 1
fi

tag_type="$(git cat-file -t "$tag_ref" 2>/dev/null || true)"
if [ "$tag_type" != tag ]; then
  echo "::error::Release tag must be an annotated tag: $tag_ref" >&2
  exit 1
fi

if ! release_commit="$(git rev-parse --verify "$tag_ref^{commit}" 2>/dev/null)"; then
  echo "::error::Release tag does not peel to a commit: $tag_ref" >&2
  exit 1
fi

printf '%s\n' "$release_commit"
