# Releasing Banyan

Run releases from a clean macOS checkout with Xcode, the GitHub CLI, and a
valid `Developer ID Application` certificate installed in the login keychain.
Any checkout that contains `origin/main` works: the main checkout, or a linked
worktree on a branch or a detached HEAD. A worktree keeps unrelated local work
in the main checkout out of the release:

```sh
git worktree add --detach .worktrees/release origin/main
cd .worktrees/release
```

1. Make and commit the changes to release.
2. Confirm the checks you want to run. The full suite is `swift test`.
3. Run:

   ```sh
   ./scripts/release.sh 0.1.0
   ```

   Before building, the script refuses a HEAD that does not contain
   `origin/main`, and a version whose tag or GitHub release (a draft included)
   already exists. If the version defaults that local builds stamp
   (`scripts/package-app.sh`, `scripts/dev-watch.sh`, and the `AppUpdater`
   fallback) are not 0.1.0 yet, it commits `chore: bump version to 0.1.0`, so
   local builds stop offering the release as an update on every launch.

   It then builds the release app, signs it with the first available
   Developer ID certificate, creates `dist/Banyan-0.1.0.dmg`, verifies both the
   app signature and DMG, pushes the release commit to `main`, creates tag
   `v0.1.0`, and uploads the DMG to the GitHub release.

Use a specific certificate when more than one is installed:

```sh
BANYAN_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  ./scripts/release.sh 0.1.0
```

The app is signed for local distribution. Notarization and stapling are not
currently part of this workflow; add those steps before distributing outside
your trusted users.
