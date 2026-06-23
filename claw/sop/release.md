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

1. Start clean and up to date.

```bash
git fetch origin --tags --prune
git status -sb
git tag --list 'v*' --sort=-v:refname | head
```

2. Choose the version and next Android version code.

```bash
VERSION=0.1.1
VERSION_CODE=$(( $(git rev-list --count HEAD) + 1 ))
```

3. Update `xr/export_presets.cfg`.

Set both `Meta Quest` and `Pico` presets:

```text
version/code=<VERSION_CODE>
version/name="<VERSION>"
```

4. Run static checks.

```bash
python3 tests/validate_xr_features.py
python3 tests/validate_xr_test_manifests.py
bash tests/03_godot_mujoco_static.sh
git diff --check
```

5. Commit and tag.

```bash
git add xr/export_presets.cfg
git commit -m "release v${VERSION}"
git tag -a "v${VERSION}" -m "Operator v${VERSION}"
```

6. Build Pico and Quest APKs.

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
AAPT=/Users/duino/Library/Android/sdk/build-tools/36.0.0/aapt
$AAPT dump badging xr/build/pico/Operator.apk | sed -n '1p'
$AAPT dump badging xr/build/quest/Operator.apk | sed -n '1p'
```

Both must show the selected `versionCode` and `versionName`.

8. Prepare release assets.

```bash
mkdir -p xr/dist
cp -f xr/build/pico/Operator.apk "xr/dist/Operator-v${VERSION}-pico.apk"
cp -f xr/build/quest/Operator.apk "xr/dist/Operator-v${VERSION}-quest.apk"
(cd xr/dist && shasum -a 256 \
  "Operator-v${VERSION}-pico.apk" \
  "Operator-v${VERSION}-quest.apk" \
  > "Operator-v${VERSION}-SHA256SUMS.txt")
```

9. Push code and tag.

```bash
git push origin main
git push origin "v${VERSION}"
```

10. Create GitHub Release and upload assets.

```bash
notes_file=$(mktemp)
cat > "$notes_file" <<EOF
Operator v${VERSION}

Builds:
- Operator-v${VERSION}-pico.apk
- Operator-v${VERSION}-quest.apk

Validation:
- python3 tests/validate_xr_features.py
- python3 tests/validate_xr_test_manifests.py
- bash tests/03_godot_mujoco_static.sh
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

11. Verify the release.

```bash
gh release view "v${VERSION}" \
  --json tagName,url,name,isDraft,isPrerelease,assets,publishedAt
git status -sb
```

The release should contain the Pico APK, Quest APK, and SHA256 file.
