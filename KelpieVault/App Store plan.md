---
note: The path from the round-7 build to a free Kelpie on the App Store — what is done, what needs Anthony's decision, and the gates.
---

# App Store plan

Written 2026-09-11 from two reconnaissance passes (`Archive/round7/appstore-repo-recon.md`, `Archive/round7/appstore-apple-rules.md`). Anthony's brief: free app, donate-to-the-dev maybe later, no TestFlight testing, a subreddit for feedback. Record his answers in [[Feedback log]].

## Answers (2026-09-11, see [[Feedback log]])

1 iPad-only: **yes, done** (`540b8d6`). 2 public repo: **public, pushed**. 3 reviewer VPS: **yes**; runbook at `docs/guides/app-review-host.md`; provider account still his. 4 relay: he is doing `wrangler login` in Terminal.app (the session shell's two-minute cap killed the first OAuth callback) and will create the APNs key. 5 name/subtitle: fine. 6 icon: draft 2 chosen and in the Icon Composer bundle (`ea19e7c`). 7 `r/KelpieConsole`: confirmed. 8 tip jar: **in 1.0, built** (`540b8d6`; needs the Paid Apps agreement and the three consumables created in App Store Connect — gate).

## Decisions only Anthony can make (original list)

1. **iPad-only or universal?** The project still targets iPhone and iPad (`TARGETED_DEVICE_FAMILY: "1,2"`). Universal means iPhone 6.9" screenshots and an iPhone layout nobody has run; the root screen is herdr's full TUI, which is unusable at phone width. *Recommendation: iPad-only for 1.0* (device family 2, opt out of "Designed for iPad" on Mac and Vision). One line in `project.yml`.
2. **Where the code lives, and public or private.** The privacy policy URL must be publicly reachable. The builder pointed the in-app links at `https://github.com/Getterbetter/Kelpie` and `…/blob/kelpie/PRIVACY.md`. That only works if the repo is pushed there *and public*. An Apache-2.0 fork is naturally public; a private repo needs a separate public page (GitHub Pages site, or a one-file public repo). *Recommendation: public repo; it also satisfies Apache's "state your changes" expectation via the commit history.*
3. **App Review access.** Kelpie does nothing without a Mac running herdr, and the demo mode is compiled out of every device build. Options: (a) a small VPS running herdr that reviewers pair with via a Pairing Code in the review notes — upstream's `docs/guides/vps-jump-host.md` is the recipe; (b) reviewer notes plus a screen-recorded demo video only; (c) build a "Try the demo" path into the Welcome screen from `Sources/Heeler/Demo/DemoScreenshotMode.swift` — but it fakes Heeler's console, not the herdr TUI that is Kelpie's root. *Recommendation: (a) and (b) together; (c) is a week of work for a fake.* Costs a few dollars a month while in review.
4. **Push notifications in 1.0.** As forked, push cannot work: the shared relay's APNs topic is Heeler's bundle id, so it can never deliver to `TME.Kelpie`. Either deploy Kelpie's own relay (Cloudflare Worker from `relay/`, free tier; needs an APNs auth key `.p8` created in the developer portal and a Cloudflare account — both his logins) or ship 1.0 with notifications off and say so. *Recommendation: deploy the relay; it is the whole reason Heeler's console was kept.* Gate: outward-facing.
5. **App name and subtitle.** "Kelpie" has no exact collision on the App Store today. Keep "herdr" out of the *name* (4.1(c), not his mark); put it in the subtitle, e.g. "Kelpie — herdr console for iPad". Thirty characters each.
6. **The icon.** Still Heeler's dog (`Sources/Heeler/AppIcon.icon/Assets/heeler-side-profile.png`). A Kelpie is the Australian working dog, so the theme continues. He supplies one, or we draft options.
7. **Subreddit name.** Placeholder everywhere is `r/KelpieConsole`. Support URL and the privacy policy contact both point at it.
8. **Donate later.** Outside the US storefront an in-app donation must be an In-App Purchase (consumable tip, 3.1.1). External Ko-fi/Sponsors links are US-only. A subreddit link is fine anywhere. Nothing in 1.0.

## Done locally (round 7b, no gate needed)

- Round 7c: iPad-only on all three targets; StoreKit 2 tip jar (`TME.Kelpie.tip.small|medium|large`) from Settings and the Kelpie menu, `Kelpie.storekit` on the scheme for local testing — confirm once in Xcode (Edit Scheme → Run → Options) that the StoreKit configuration is picked up, then buy a test tip on the iPad.

- Visible rebrand leftovers fixed (camera usage string, extension display names, Settings and privacy links), `NOTICE` added, Heeler credited on the Acknowledgements screen, `PRIVACY.md` rewritten for Kelpie, `NSLocalNetworkUsageDescription` added, relay config topic set to `TME.Kelpie`, `publish.sh` takes `PUBLISH_REMOTE`/`PUBLISH_BRANCH`, version reset to 1.0 (1). Detail in `Archive/round7/appstore-build.md`.
- Internal identifiers deliberately left: Keychain service names and access groups (changing them orphans keys on the iPad), the logger subsystem, module/target/scheme names.

## Status at 2026-09-12 (round 8)

Done: repo public; relay deployed and keyed; ASC record filled by `scripts/asc-kelpie.py`; build 1 uploaded (VALID); review host up with staged demo; store panels rendered; driver lane for the iPad. Left: Anthony runs `--apply --screenshots`, `--apply --iap-screenshots`, `--apply --attach-build --review-details … --review-attachment`, then `--submit` on his word. After approval: tear down the Hetzner server. Known: the App Store Connect key is App Manager, so cloud signing fails — use the created App Store profiles (manual signing, `scratchpad/…/signing/ExportOptions-manual.plist` pattern) or Xcode's signed-in account (Anthony signed in on 2026-09-12).

## Status at 2026-09-12 (round 9) — submitted

TestFlight builds 3 (2026-09-13), 4 and 5 (2026-09-15) were uploaded but never added to the public group or submitted for beta review, so the 16 testers are on build 2 (found 2026-09-15, round 21); `make distribute APPLY=1` put build 5 in the group the same day; it went straight to `IN_BETA_TESTING` because the version's beta review was already approved (Open item 41). Submitted for App Review 2026-09-12 02:20 UTC: version 1.0 (build 1) and the three tip consumables, all **Waiting for Review**. Name changed to **Kelpie for herdr**, subtitle **Agent console for iPad** (Heeler ships as "Heeler for herdr"; Moshi also carries the mark). What the submit needed beyond the script: content rights declaration (does not use third-party content), version copyright "2026 Anthony Topalides", a free price schedule (base territory AUS), App Privacy published by hand in the web UI (Identifiers → Device ID, app functionality, not linked, not tracking — the `appDataUsages` API is gone), and the tips added to the draft submission on the App Review page by hand (a first consumable has no API route). The IAP review screenshot had to be 2732x2048 (`iap/tip-sheet-2732x2048.png`, letterboxed); the original 2816x1940 was rejected `IMAGE_INCORRECT_DIMENSIONS`. Review contact is Anthony's mobile and his iCloud address. **TestFlight public beta** (2026-09-12, Anthony's yes): external group "Kelpie public beta" with public link `https://testflight.apple.com/join/AkJxAbnJ`, build 1 attached, beta app description + feedback email + privacy URL set, beta review notes = the App Review notes (same review host), Beta App Review **approved 2026-09-12**, the public link is live;  the Hetzner host must outlive both reviews. Later builds for testers: `make bump && make archive`, then export with the manual-signing plist (`destination: export`) and upload with `xcrun altool --upload-app -f Kelpie.ipa -t ios --apiKey 6T785PX2FV --apiIssuer <issuer>` — `make upload` fails with "Failed to Use Accounts" because no Apple ID with App Store Connect access is signed into Xcode on this Mac (build 2 went up this way 2026-09-12 19:34). Then add the build to the group (`POST /v1/betaGroups/079385a3-…/relationships/builds`) and submit it for beta review. **Next: wait for the review result, then tear down the Hetzner host** (`docs/guides/app-review-host.md`).

## Public-repo sweep (2026-09-12)

Sweep before the community push found the App Review clip (`Design/Store Screenshots/review/app-review.mp4`, committed in round 8) opening on Anthony's lock screen: a family photo, a child's birthday calendar entry with the venue address, and later his Mac's LAN SSH login. Purged from every commit with `git filter-repo` in a fresh clone and force-pushed (Anthony's yes); **every commit hash after `cf45aea` quoted in this vault is now stale** (the rewrite re-hashed the branch and the pre-rebase tag). The clip lives at `~/Developer/kelpie-private/app-review.mp4`, outside the repo; `.gitignore` now excludes `*.mp4`/`*.mov` under the vault. GitHub may still serve the old blobs by SHA until support purges them; ask via https://support.github.com if it matters. Rule from now on: no recording or screenshot is committed until someone has looked at its first and last frames.

## Gates, in order

1. ~~Push the repo~~ Done 2026-09-11: public `https://github.com/Getterbetter/Kelpie`; the in-app privacy link resolves.
2. ~~Deploy the relay~~ Done 2026-09-11: `https://kelpie-apns.getter-tilbury-0m.workers.dev` (Cloudflare account under his iCloud address, `workers_dev`). App and plugin defaults point at it; Heeler's old relay is on the legacy list so an existing install migrates. APNs key 7RJ68B8QX8 added as a Wrangler secret 2026-09-11; the relay answers 404 `not_found` at the root, not 500.
3. ~~Create the app record in App Store Connect (bundle `TME.Kelpie`, name, subtitle, category Developer Tools, age rating 4+, privacy labels: Identifiers → Device ID, linked to nothing, not used for tracking), sign the Paid Apps agreement (bank + tax, once), and create the three consumable IAPs with the ids above.~~ Done 2026-09-11: record 6811004082 filled by `scripts/asc-kelpie.py`.
4. ~~`make bump && make testflight` uploads the archive (do not use `make publish` for 1.0 without `VERSION=1.0`: it derives 0.1.7 from Heeler's CHANGELOG) (TestFlight is just the upload path; no tester groups). Export compliance answers: uses encryption, standard algorithms only, exempt.~~ Done 2026-09-12: build 1 uploaded, VALID.
5. ~~Screenshots from the iPad itself (13" set is mandatory; 11" captures are accepted and scaled) — Anthony's hands, herdr running.~~ Done 2026-09-12: four panels from `Design/Store Screenshots/final-13in/` uploaded with `--apply --screenshots`.
6. ~~Submit for review with the notes and video from decision 3.~~ Done 2026-09-12 02:20 UTC, see the round-9 status above.

## Apple rules that bit, verified 2026-09-11

- Privacy manifest is mandatory; wrong required-reason entries are a hard rejection (ITMS-91053). Upstream's manifest ships unchanged and is believed correct.
- Age rating tiers changed July 2025 (4+/9+/13+/16+/18+); the questionnaire must be redone for a new app.
- A push device token counts as collected data (Identifiers) on the privacy label.
- Privacy Policy URL and Support URL are both mandatory.

Related: [[Open items]] · [[Heeler upstream]] · [[Feedback log]]
