#!/usr/bin/env bash
#
# Cut a Mana release: build the .dmg, publish it as a GitHub Release, and point
# the Homebrew cask at it.
#
# Usage:
#   scripts/release.sh                 # release the version in project.yml
#   scripts/release.sh --dry-run       # build + print what would be published
#
# Env overrides:
#   MANA_TAP_DIR   Checkout of the Homebrew tap that holds Casks/mana.rb.
#                  Defaults to Homebrew's own tap directory, which is where
#                  `brew tap TinyFrontier/tap` puts it. When the directory is
#                  not a git checkout with a remote, the cask is updated in
#                  place and pushing is left to you.
#
# The version is whatever the built app reports (project.yml → Info.plist);
# this script never invents one. Bump `CFBundleShortVersionString` and
# `MARKETING_VERSION` in project.yml first.
#
# Refuses to overwrite an existing tag or release — re-releasing the same
# version silently is how users end up with two different builds under one
# version number.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO="TinyFrontier/mana_bar"
CASK_SOURCE="$ROOT_DIR/packaging/homebrew/mana.rb"
DEFAULT_TAP_DIR="$(brew --repository 2>/dev/null || echo /opt/homebrew)/Library/Taps/tinyfrontier/homebrew-tap"
TAP_DIR="${MANA_TAP_DIR:-$DEFAULT_TAP_DIR}"

DRY_RUN="no"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN="yes"
fi

section() {
  echo
  echo "=== $1 ==="
}

die() {
  echo "error: $1" >&2
  exit 1
}

# --- 1. Preconditions -----------------------------------------------------

section "Preconditions"

command -v gh >/dev/null || die "gh CLI is required (brew install gh)"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"

cd "$ROOT_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
  die "working tree is dirty — commit or stash before cutting a release"
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
  echo "warning: releasing from '$BRANCH', not main"
fi

git fetch --quiet origin
LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse "origin/$BRANCH" 2>/dev/null || echo none)"
if [[ "$REMOTE" != "none" && "$LOCAL" != "$REMOTE" ]]; then
  die "HEAD differs from origin/$BRANCH — push first, so the release tag points at published code"
fi

echo "branch:   $BRANCH"
echo "commit:   ${LOCAL:0:7}"

# --- 2. Build -------------------------------------------------------------

section "Build .dmg"
"$SCRIPT_DIR/package-dmg.sh"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$ROOT_DIR/dist/work/build/Mana.app/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "$VERSION" ]]; then
  # Fall back to the .dmg name the packaging script just produced.
  VERSION="$(ls -t "$ROOT_DIR"/dist/Mana-*.dmg | head -1 | sed -E 's/.*Mana-(.*)\.dmg/\1/')"
fi
[[ -n "$VERSION" ]] || die "could not determine the version"

TAG="v$VERSION"
DMG_PATH="$ROOT_DIR/dist/Mana-$VERSION.dmg"
[[ -f "$DMG_PATH" ]] || die "expected $DMG_PATH to exist after the build"

SHA256="$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"

echo "version:  $VERSION"
echo "tag:      $TAG"
echo "dmg:      $DMG_PATH"
echo "sha256:   $SHA256"

# --- 3. Refuse to clobber an existing release -----------------------------

if git rev-parse "$TAG" >/dev/null 2>&1; then
  die "tag $TAG already exists locally — bump the version in project.yml"
fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  die "release $TAG already exists on $REPO — bump the version in project.yml"
fi

if [[ "$DRY_RUN" == "yes" ]]; then
  section "Dry run"
  echo "would tag $TAG at ${LOCAL:0:7}"
  echo "would create release $TAG on $REPO with $(basename "$DMG_PATH")"
  echo "would update $CASK_SOURCE to version $VERSION / sha256 $SHA256"
  exit 0
fi

# --- 4. Tag and publish ---------------------------------------------------

section "Tag"
git tag -a "$TAG" -m "Mana $VERSION"
git push origin "$TAG"

section "GitHub Release"
gh release create "$TAG" \
  "$DMG_PATH" \
  "$DMG_PATH.sha256" \
  --repo "$REPO" \
  --title "Mana $VERSION" \
  --notes "Install: \`brew install --cask --no-quarantine TinyFrontier/tap/mana\`

Not notarized (needs a paid Apple Developer Program membership), so Gatekeeper
refuses this build as if downloaded. The cask strips the quarantine attribute;
for a manual download use right-click → Open, or
\`xattr -d com.apple.quarantine /Applications/Mana.app\`.

Requires macOS 13 (Ventura) or later."

# --- 5. Update the cask ---------------------------------------------------

section "Update cask"

# Only the two lines that change per release; the rest of the cask is hand-
# maintained and must survive untouched.
/usr/bin/sed -i '' \
  -e "s/^  version \".*\"$/  version \"$VERSION\"/" \
  -e "s/^  sha256 \".*\"$/  sha256 \"$SHA256\"/" \
  "$CASK_SOURCE"

grep -E '^  (version|sha256) ' "$CASK_SOURCE"

if [[ -d "$TAP_DIR/Casks" ]]; then
  cp "$CASK_SOURCE" "$TAP_DIR/Casks/mana.rb"
  echo "copied cask into $TAP_DIR/Casks/mana.rb"

  # Must be the tap's *own* checkout: a tap installed by `brew tap` sits inside
  # /opt/homebrew, which is itself a git repository, so a bare `rev-parse`
  # succeeds there and would commit into Homebrew's own tree.
  TAP_TOPLEVEL="$(git -C "$TAP_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ "$TAP_TOPLEVEL" == "$TAP_DIR" ]]; then
    git -C "$TAP_DIR" add Casks/mana.rb
    git -C "$TAP_DIR" commit -m "mana $VERSION"
    if git -C "$TAP_DIR" remote get-url origin >/dev/null 2>&1; then
      git -C "$TAP_DIR" push
      echo "pushed the tap"
    else
      echo "tap has no 'origin' remote — push it yourself"
    fi
  else
    echo "$TAP_DIR is not its own git checkout — commit and push the cask yourself"
  fi
else
  echo "no tap checkout at $TAP_DIR — set MANA_TAP_DIR, or copy $CASK_SOURCE into the tap yourself"
fi

section "Done"
echo "release:  https://github.com/$REPO/releases/tag/$TAG"
echo "install:  brew install --cask TinyFrontier/tap/mana"
echo
echo "Commit the updated cask in this repository:"
echo "  git add packaging/homebrew/mana.rb && git commit -m \"Point the cask at $VERSION\""
