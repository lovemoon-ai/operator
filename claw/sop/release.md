# Release SOP

Use this for Operator releases. One version, the root `VERSION` file, covers
the Rust crates, the `operator-xr` Python package, `cpp/liboperator`, and the XR
APK. A release publishes the Pico and Quest APKs to GitHub Releases and
`operator-xr` to PyPI.

## Version Model

- `VERSION` holds `MAJOR.MINOR.PATCH`.
  `python3 scripts/version.py set <version>` writes it together with its only
  other copies, `robot/Cargo.toml` (`[workspace.package]`, plus `Cargo.lock`)
  and `xr/project.godot` (`application/config/version`); Python and C++ read
  it at build time.
  `python3 scripts/version.py check [--tag v<version>]` fails on any drift.
- The `operator-features` export plugin stamps every APK at export time:
  `versionName` is the version, `versionCode` is `git rev-list --count HEAD`,
  and the short commit is shown on the Teleop and Ego **Build info** page. Do
  not edit `version/*` in `xr/export_presets.cfg`.
- Pushing the `v<version>` tag runs `.github/workflows/python-release.yml`,
  which builds the `operator-xr` wheels (Linux x86_64/aarch64, macOS arm64) and
  sdist and publishes them to PyPI. PyPI accepts each version only once, so a
  bad release is fixed by releasing the next patch version, never by re-tagging.

## Account

Use the `dang217` GitHub CLI account for the whole release: it can push, run
workflows, and create releases. The repository remote is
`github-dang217:lovemoon-ai/operator.git`.

```bash
gh auth switch -h github.com -u dang217
gh auth status
```

If `gh release create` fails with a scope error, refresh the active account:

```bash
gh auth refresh -h github.com -s workflow
```

PyPI uses Trusted Publishing, so no token is stored anywhere. The `operator-xr`
project on pypi.org must keep this trusted publisher; recheck it if publishing
fails with `invalid-publisher`:

| Field | Value |
| --- | --- |
| Owner | `lovemoon-ai` |
| Repository | `operator` |
| Workflow | `python-release.yml` |
| Environment | `pypi` |

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

3. Set the release version.

```bash
python3 scripts/version.py set "$VERSION"
git status -sb
```

`set` is idempotent. If `VERSION` already holds the release version, nothing
changes and step 5 has nothing to commit.

4. Run static checks.

```bash
python3 scripts/version.py check
python3 cicd/validate_xr_features.py
python3 cicd/validate_xr_test_manifests.py
bash cicd/03_godot_mujoco_static.sh
git diff --check
```

5. Commit and tag.

```bash
git add VERSION robot/Cargo.toml robot/Cargo.lock xr/project.godot
git diff --cached --quiet || git commit -m "release v${VERSION}"
git tag -a "v${VERSION}" -m "Operator v${VERSION}"
python3 scripts/version.py check --tag "v${VERSION}"
```

6. Build Pico and Quest APKs from the tagged commit.

The export plugin reads `versionCode` and the Build info commit from `HEAD`, so
build only after step 5.

```bash
make -C xr build-pico build-quest
```

Expected outputs:

```text
xr/build/pico/Operator.apk
xr/build/quest/Operator.apk
```

7. Verify APK versions.

```bash
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
AAPT="$(ls -d "$SDK"/build-tools/*/aapt | tail -1)"
echo "expected: versionCode=$(git rev-list --count HEAD)" \
  "versionName=${VERSION} commit=$(git rev-parse --short HEAD)"
for apk in xr/build/pico/Operator.apk xr/build/quest/Operator.apk; do
  "$AAPT" dump badging "$apk" | sed -n '1p'
  unzip -p "$apk" assets/build_info.cfg
done
```

Both APKs must show the expected `versionCode`, `versionName`, and commit.

8. Prepare release assets.

```bash
mkdir -p xr/dist
cp -f xr/build/pico/Operator.apk "xr/dist/Operator-v${VERSION}-pico.apk"
cp -f xr/build/quest/Operator.apk "xr/dist/Operator-v${VERSION}-quest.apk"
cp -f "claw/qa-artifacts/v${VERSION}/test-report.html" \
  "xr/dist/Operator-v${VERSION}-QA-report.html"
(cd xr/dist && shasum -a 256 \
  "Operator-v${VERSION}-pico.apk" \
  "Operator-v${VERSION}-quest.apk" \
  > "Operator-v${VERSION}-SHA256SUMS.txt")
```

9. Push `main` and dry-run the Python release.

Pushing the tag publishes to PyPI immediately and cannot be undone, so first
prove the release commit builds. A manual run builds and smoke-tests every wheel
and the sdist and skips `publish`.

```bash
git push origin main
gh workflow run python-release.yml -R lovemoon-ai/operator --ref main
sleep 15
RUN_ID="$(gh run list -R lovemoon-ai/operator --workflow python-release.yml \
  --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run watch "$RUN_ID" -R lovemoon-ai/operator --exit-status
```

Continue only if every job passes.

10. Push the tag to publish to PyPI.

```bash
git push origin "v${VERSION}"
sleep 15
RUN_ID="$(gh run list -R lovemoon-ai/operator --workflow python-release.yml \
  --event push --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run watch "$RUN_ID" -R lovemoon-ai/operator --exit-status
```

If the run fails before `publish`, nothing reached PyPI. Delete the tag, fix
`main`, and redo from step 5:

```bash
git tag -d "v${VERSION}"
git push origin ":refs/tags/v${VERSION}"
```

Once `publish` succeeds the version is final.

11. Verify the PyPI release in a clean environment.

PyPI can take a minute to serve a new version.

```bash
python3 -m venv /tmp/operator-xr-check
/tmp/operator-xr-check/bin/pip install --no-cache-dir "operator-xr==${VERSION}"
/tmp/operator-xr-check/bin/operator --version
/tmp/operator-xr-check/bin/python -c \
  "import operator_xr, operator_xr._native; print(operator_xr.__version__)"
rm -rf /tmp/operator-xr-check
```

Both commands must print `${VERSION}`.

12. Create GitHub Release and upload assets.

Release notes must be concise and user-facing:

- Do not start the body with `Operator v${VERSION}` because it duplicates the
  release title.
- Include a `Changelog` section with `Added`, `Changed`, and `Fixed`
  subsections when applicable.
- Include the one-line Python SDK install command.
- Do not include `QA Summary`, `Builds`, or `Validation` sections; QA is already
  enforced by the release gate, and release assets are shown by GitHub.
- End with one short English feedback invitation. Vary this sentence between
  releases.

```bash
notes_file=$(mktemp)
cat > "$notes_file" <<EOF
Changelog

Added
- <new user-facing capability>

Changed
- <changed behavior or compatibility note>

Fixed
- <bug fix or reliability improvement>

Python SDK: pip install operator-xr==${VERSION}

Please try it out and keep the feedback coming.
EOF

gh release create "v${VERSION}" \
  "xr/dist/Operator-v${VERSION}-pico.apk" \
  "xr/dist/Operator-v${VERSION}-quest.apk" \
  "xr/dist/Operator-v${VERSION}-QA-report.html" \
  "xr/dist/Operator-v${VERSION}-SHA256SUMS.txt" \
  --title "Operator v${VERSION}" \
  --notes-file "$notes_file"

rm -f "$notes_file"
```

13. Verify the release.

```bash
gh release view "v${VERSION}" \
  --json tagName,url,name,isDraft,isPrerelease,assets,publishedAt
curl -fsS "https://pypi.org/pypi/operator-xr/${VERSION}/json" >/dev/null && echo "PyPI OK"
git status -sb
```

The release should contain the Pico APK, Quest APK, QA report HTML, and SHA256
file, and PyPI should serve `operator-xr` `${VERSION}`.

## PyPI-Only Release

To publish only the Python package, run steps 1–5 and 9–11 and skip the APK
build and the GitHub Release. To attach APKs to that tag later, check out the
tag, then run steps 6–8 and 12–13. The APKs then carry the tag's commit and
`versionCode`.
