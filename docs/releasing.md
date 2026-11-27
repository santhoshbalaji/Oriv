# Releasing Oriv for Mac

The public beta ships as a notarized DMG on GitHub Releases. Sparkle updates installed copies from the feed at `https://oriv.dev/appcast.xml`. Only the `OrivReleaseMac` scheme (ContinuityRelease configuration) has a feed URL. Development, test and ad-hoc builds never start the updater.

## One-time setup on the release Mac

1. **Developer ID Application certificate.** Only the team's Account Holder can create it. In Xcode, open **Settings → Accounts**, select the team and choose **Manage Certificates… → + → Developer ID Application**. The certificate and its private key go into the login keychain. Back them up with **Export…** (a password-protected `.p12`) somewhere safe.
2. **Notarization credentials.** In App Store Connect, open **Users and Access → Integrations → App Store Connect API**. Create a team key with the Developer role and download the `.p8` file; you can download it only once. Then store it in the keychain:

   ```
   xcrun notarytool store-credentials oriv-notary --key AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
   ```

   Keep the `.p8` file somewhere private, or delete it after storing.
3. **Sparkle signing key.** It's already created on the release Mac (login keychain item `https://sparkle-project.org`). Its public half is `ORIV_SPARKLE_PUBLIC_KEY` in `project.yml`. Back up the private half, because without it no installed copy can be updated:

   ```
   build/DevDerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
   ```

   Store that file in your password manager, then delete it. When `sign_update` first asks for keychain access, choose **Always Allow**.

## Each release

1. Set `MARKETING_VERSION` and a higher `CURRENT_PROJECT_VERSION` in `project.yml` for both apps. Run `xcodegen generate`, and add a `## <version>` section to `docs/releases/CHANGELOG.md`.
2. Commit, then run `ORIV_DEVELOPMENT_TEAM=<team> scripts/release-mac.sh` from a clean checkout of that commit. The script:
   - archives a universal build and exports it with Developer ID;
   - checks the signature, hardened runtime, sandbox and production iCloud entitlements, and the feed URL;
   - notarizes and staples the app;
   - builds, signs, notarizes and staples the DMG, then checks it with Gatekeeper;
   - signs the DMG for Sparkle and adds it to `site/appcast.xml`.
3. To publish, rerun with `--publish`, or do it by hand: tag `v<version>`, then create a GitHub **prerelease** with the DMG and its `.sha256`, using that version's changelog section as notes.
4. Commit `site/appcast.xml`, and point the **Download DMG** link in `site/index.html` at the new DMG. GitHub's `/releases/latest` skips prereleases, so the link names the version. Merge to `main`, and the Pages workflow publishes the feed, at which point installed copies see the update.

Publish the GitHub release before the appcast reaches oriv.dev, so the DMG link works when Sparkle first sees it.

## Versions

`docs/releases/history.json` maps every private build (0.5.0–0.29.0) to its commit, and each has a `v<version>` tag. The public beta starts at 0.30.0. Versions before it were never distributed.

# Releasing Oriv for iPhone

The iPhone app (`com.santhoshbalaji.oriv.ios`) is iPhone-only and goes out through TestFlight, then the App Store. It meets Apple's default-browser requirements: http/https schemes, WebKit only, a start page with an address field, and no full photo-library, always-on location, HomeKit, Bluetooth or Health permissions. The default-browser entitlement is added to `Apps/iOS/ContinuityRelease.entitlements` only after Apple grants it.

## One-time setup

1. Create the app in App Store Connect: **Apps → + → New App**, platform iOS, bundle ID `com.santhoshbalaji.oriv.ios`.
2. Put the App Store Connect API key at `$HOME/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` on the release Mac (mode 600). The same key also serves notarization.

## Each upload

Use a `CURRENT_PROJECT_VERSION` higher than any build already uploaded. Commit, then run:

```
ORIV_DEVELOPMENT_TEAM=<team> ORIV_ASC_ISSUER_ID=<issuer> scripts/release-iphone.sh
```

The script archives the ContinuityRelease build, then checks the bundle ID, build number, iPhone-only device family, privacy manifest and the default-browser privacy rules. It then uploads to App Store Connect. The build appears in TestFlight after Apple processes it. External testers and a public link need Beta App Review once per version.
