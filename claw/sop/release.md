# Release SOP

Use this for Operator APK releases that publish both Pico and Quest builds to
GitHub Releases.

## Account

Use the `dang217` GitHub CLI account for release creation and asset upload.
The repository remote is `github-dang217:lovemoon-ai/operator.git`.

```bash
gh auth switch -h github.com -u dang217
gh auth status
```

If `gh release create` fails with a scope error, refresh the active account:

```bash
gh auth refresh -h github.com -s workflow
```

## Steps

1. Select the latest QA-tested version and verify the QA artifact gate.

This is the release gate. Do not edit version files, commit, tag, build release
APKs, push, or create a GitHub Release until this step passes.

The QA artifact version is the single source of truth for the release version.
If `claw/qa-artifacts/` contains multiple `vMAJOR.MINOR.PATCH` directories,
select the largest semantic version and release exactly that version. The QA
artifact directory must then be exactly
`claw/qa-artifacts/v${RELEASE_VERSION}`, and it must contain a passing HTML test
report from the QA process.

If the desired release version differs from the largest QA artifact version,
refuse the release and rerun QA for the desired version under a matching
`claw/qa-artifacts/v<version>/` directory.

If the artifact is missing, incomplete, `FAIL`, `PARTIAL`, or `NOT RUN`, refuse
the release and run QA first.

```bash
set -euo pipefail

QA_ARTIFACT_ROOT="claw/qa-artifacts"
RELEASE_VERSION="$(
  python3 - "$QA_ARTIFACT_ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
versions = []
if root.exists():
    for path in root.iterdir():
        if not path.is_dir():
            continue
        match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", path.name)
        if match:
            parts = tuple(int(value) for value in match.groups())
            version = ".".join(match.groups())
            versions.append((parts, version))

if not versions:
    raise SystemExit(f"No QA artifact version directories found under {root}")

print(max(versions)[1])
PY
)"
VERSION="$RELEASE_VERSION"
EXPECTED_QA_ARTIFACT_DIR="${QA_ARTIFACT_ROOT}/v${RELEASE_VERSION}"
QA_ARTIFACT_DIR="$EXPECTED_QA_ARTIFACT_DIR"
QA_PLAN="${QA_ARTIFACT_DIR}/qa-test-plan.md"
QA_REPORT="${QA_ARTIFACT_DIR}/test-report.html"
QA_RUNS="${QA_ARTIFACT_DIR}/runs"

if [ "$QA_ARTIFACT_DIR" != "$EXPECTED_QA_ARTIFACT_DIR" ]; then
  echo "Refuse release: QA artifact dir '$QA_ARTIFACT_DIR' does not match release version '$RELEASE_VERSION'." >&2
  exit 1
fi

test -s "$QA_PLAN"
test -s "$QA_REPORT"
test -d "$QA_RUNS"
find "$QA_RUNS" -mindepth 1 -maxdepth 1 -type d | grep -q .

python3 - "$QA_REPORT" "$RELEASE_VERSION" <<'PY'
from pathlib import Path
import re
import sys

report = Path(sys.argv[1])
release_version = sys.argv[2]
html = report.read_text(encoding="utf-8", errors="replace")
if f"v{release_version}" not in html and release_version not in html:
    raise SystemExit(
        f"QA report does not mention release version {release_version}: {report}"
    )

status_re = re.compile(
    r'<span[^>]*class=["\']([^"\']*\bstatus\b[^"\']*)["\'][^>]*>\s*([^<]+)\s*</span>',
    re.IGNORECASE,
)
statuses = [
    (classes.lower(), label.strip().upper())
    for classes, label in status_re.findall(html)
]
if not statuses:
    raise SystemExit(f"QA report has no status markers: {report}")

overall_classes, overall_label = statuses[0]
if "pass" not in overall_classes or overall_label != "PASS":
    raise SystemExit(f"QA report overall status is not PASS: {overall_label}")

blocking = []
for classes, label in statuses:
    compact_classes = classes.replace(" ", "_").replace("-", "_")
    compact_label = label.replace(" ", "").replace("-", "_")
    if (
        "fail" in classes
        or "partial" in classes
        or "not_run" in compact_classes
        or label in {"FAIL", "PARTIAL", "NOT RUN"}
        or compact_label in {"NOTRUN", "NOT_RUN"}
    ):
        blocking.append(label)

if blocking:
    raise SystemExit(f"QA report contains blocking statuses: {blocking}")

print(f"QA_GATE_PASS {report}")
PY
```

Do not create or edit QA artifacts just to satisfy this gate. The artifacts must
come from the QA run for the same release version. If the report format changes,
update this gate to keep the same rule: only a complete `PASS` report can enter
release.

2. Start clean and up to date.

```bash
git fetch origin --tags --prune
git status -sb
git tag --list 'v*' --sort=-v:refname | head
```

3. Choose the next Android version code.

```bash
VERSION_CODE=$(( $(git rev-list --count HEAD) + 1 ))
```

4. Update `xr/export_presets.cfg`.

Set both `Meta Quest` and `Pico` presets:

```text
version/code=<VERSION_CODE>
version/name="<VERSION>"
```

5. Run static checks.

```bash
python3 cicd/validate_xr_features.py
python3 cicd/validate_xr_test_manifests.py
bash cicd/03_godot_mujoco_static.sh
git diff --check
```

6. Commit and tag.

```bash
git add xr/export_presets.cfg
git commit -m "release v${VERSION}"
git tag -a "v${VERSION}" -m "Operator v${VERSION}"
```

7. Build Pico and Quest APKs.

```bash
make -C xr build-pico build-quest
```

Expected outputs:

```text
xr/build/pico/Operator.apk
xr/build/quest/Operator.apk
```

8. Verify APK versions.

```bash
AAPT=/Users/duino/Library/Android/sdk/build-tools/36.0.0/aapt
$AAPT dump badging xr/build/pico/Operator.apk | sed -n '1p'
$AAPT dump badging xr/build/quest/Operator.apk | sed -n '1p'
```

Both must show the selected `versionCode` and `versionName`.

9. Prepare release assets.

```bash
mkdir -p xr/dist
cp -f xr/build/pico/Operator.apk "xr/dist/Operator-v${VERSION}-pico.apk"
cp -f xr/build/quest/Operator.apk "xr/dist/Operator-v${VERSION}-quest.apk"
(cd xr/dist && shasum -a 256 \
  "Operator-v${VERSION}-pico.apk" \
  "Operator-v${VERSION}-quest.apk" \
  > "Operator-v${VERSION}-SHA256SUMS.txt")
```

10. Push code and tag.

```bash
git push origin main
git push origin "v${VERSION}"
```

11. Create GitHub Release and upload assets.

```bash
notes_file=$(mktemp)
cat > "$notes_file" <<EOF
Operator v${VERSION}

Builds:
- Operator-v${VERSION}-pico.apk
- Operator-v${VERSION}-quest.apk

Validation:
- QA report: claw/qa-artifacts/v${VERSION}/test-report.html (PASS)
- python3 cicd/validate_xr_features.py
- python3 cicd/validate_xr_test_manifests.py
- bash cicd/03_godot_mujoco_static.sh
- make -C xr build-pico build-quest
EOF

gh release create "v${VERSION}" \
  "xr/dist/Operator-v${VERSION}-pico.apk" \
  "xr/dist/Operator-v${VERSION}-quest.apk" \
  "xr/dist/Operator-v${VERSION}-SHA256SUMS.txt" \
  --title "Operator v${VERSION}" \
  --notes-file "$notes_file"

rm -f "$notes_file"
```

12. Verify the release.

```bash
gh release view "v${VERSION}" \
  --json tagName,url,name,isDraft,isPrerelease,assets,publishedAt
git status -sb
```

The release should contain the Pico APK, Quest APK, and SHA256 file.
