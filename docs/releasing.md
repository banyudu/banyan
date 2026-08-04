# Releasing Banyan

Run releases from a clean macOS checkout with Xcode, the GitHub CLI, and a
valid `Developer ID Application` certificate installed in the login keychain.

1. Make and commit the changes to release.
2. Confirm the checks you want to run. The full suite is `swift test`.
3. Run:

   ```sh
   ./scripts/release.sh 0.1.0
   ```

   The script builds the release app, signs it with the first available
   Developer ID certificate, creates `dist/Banyan-0.1.0.dmg`, verifies both the
   app signature and DMG, pushes the current commit, creates tag `v0.1.0`, and
   uploads the DMG to the GitHub release.

Use a specific certificate when more than one is installed:

```sh
BANYAN_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  ./scripts/release.sh 0.1.0
```

The app is signed for local distribution. Notarization and stapling are not
currently part of this workflow; add those steps before distributing outside
your trusted users.
