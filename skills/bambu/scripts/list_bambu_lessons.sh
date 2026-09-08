#!/usr/bin/env bash
set -euo pipefail

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lessons_dir="$skill_dir/references/lessons"
index="$lessons_dir/README.md"

[[ -f "$index" ]] || {
  echo "Missing lessons index: $index" >&2
  exit 1
}

mapfile -t lessons < <(
  find "$lessons_dir" -maxdepth 1 -type f -name '*.md' ! -name README.md -printf '%f\n' | sort
)

for lesson in "${lessons[@]}"; do
  if ! grep -Fq "($lesson)" "$index"; then
    echo "Lesson is not registered in README.md: $lesson" >&2
    exit 1
  fi
done

while IFS= read -r indexed; do
  [[ -z "$indexed" ]] && continue
  if [[ ! -f "$lessons_dir/$indexed" ]]; then
    echo "Indexed lesson does not exist: $indexed" >&2
    exit 1
  fi
done < <(sed -n 's/.*](\([^)]*\.md\)).*/\1/p' "$index")

printf '%s\n' "${lessons[@]/#/$lessons_dir/}"
