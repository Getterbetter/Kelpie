---
note: The path from the round-7 build to a free Kelpie on the App Store — what is done, what needs Anthony's decision, and the gates.
---

# App Store plan

Written 2026-09-11 from two reconnaissance passes (`Archive/round7/appstore-repo-recon.md`, `Archive/round7/appstore-apple-rules.md`). Anthony's brief: free app, donate-to-the-dev maybe later, no TestFlight testing, a subreddit for feedback. Record his answers in [[Feedback log]].

## Decisions only Anthony can make

1. **iPad-only or universal?** The project still targets iPhone and iPad (`TARGETED_DEVICE_FAMILY: "1,2"`). Universal means iPhone 6.9" screenshots and an iPhone layout nobody has run; the root screen is herdr's full TUI, which is unusable at phone width. *Recommendation: iPad-only for 1.0* (device family 2, opt out of "Designed for iPad" on Mac and Vision). One line in `project.yml`.
2. **Where the code lives, and public or private.** The privacy policy URL must be publicly reachable. The builder pointed the in-app links at `https://github.com/Getterbetter/Kelpie` and `…/blob/kelpie/PRIVACY.md`. That only works if the repo is pushed there *and public*. An Apache-2.0 fork is naturally public; a private repo needs a separate public page (GitHub Pages site, or a one-file public repo). *Recommendation: public repo; it also satisfies Apache's "state your changes" expectation via the commit history.*
3. **App Review access.** Kelpie does nothing without a Mac running herdr, and the demo mode is compiled out of every device build. Options: (a) a small VPS running herdr that reviewers pair with via a Pairing Code in the review notes — upstream's `docs/guides/vps-jump-host.md` is the recipe; (b) reviewer notes plus a screen-recorded demo video only; (c) build a "Try the demo" path into the Welcome screen from `Sources/Heeler/Demo/DemoScreenshotMode.swift` — but it fakes Heeler's console, not the herdr TUI that is Kelpie's root. *Recommendation: (a) and (b) together; (c) is a week of work for a fake.* Costs a few dollars a month while in review.
4. **Push notifications in 1.0.** As forked, push cannot work: the shared relay's APNs topic is Heeler's bundle id, so it can never deliver to `TME.Kelpie`. Either deploy Kelpie's own relay (Cloudflare Worker from `relay/`, free tier; needs an APNs auth key `.p8` created in the developer portal and a Cloudflare account — both his logins) or ship 1.0 with notifications off and say so. *Recommendation: deploy the relay; it is the whole reason Heeler's console was kept.* Gate: outward-facing.
5. **App name and subtitle.** "Kelpie" has no exact collision on the App Store today. Keep "herdr" out of the *name* (4.1(c), not his mark); put it in the subtitle, e.g. "Kelpie — herdr console for iPad". Thirty characters each.
6. **The icon.** Still Heeler's dog (`Sources/Heeler/AppIcon.icon/Assets/heeler-side-profile.png`). A Kelpie is the Australian working dog, so the theme continues. He supplies one, or we draft options.
7. **Subreddit name.** Placeholder everywhere is `r/KelpieApp`. Support URL and the privacy policy contact both point at it.
8. **Donate later.** Outside the US storefront an in-app donation must be an In-App Purchase (consumable tip, 3.1.1). External Ko-fi/Sponsors links are US-only. A subreddit link is fine anywhere. Nothing in 1.0.

## Done locally (round 7b, no gate needed)

- Visible rebrand leftovers fixed (camera usage string, extension display names, Settings and privacy links), `NOTICE` added, Heeler credited on the Acknowledgements screen, `PRIVACY.md` rewritten for Kelpie, `NSLocalNetworkUsageDescription` added, relay config topic set to `TME.Kelpie`, `publish.sh` takes `PUBLISH_REMOTE`/`PUBLISH_BRANCH`, version reset to 1.0.0 (1). Detail in `Archive/round7/appstore-build.md`.
- Internal identifiers deliberately left: Keychain service names and access groups (changing them orphans keys on the iPad), the logger subsystem, module/target/scheme names.

## Gates, in order

1. Push the repo (item 0 in [[Open items]]) — `gh repo create Getterbetter/Kelpie --private|--public --source . --remote origin --push`.
2. Create the APNs key and deploy the relay (`relay/`, Wrangler), then point `NotificationRelayEndpoint.swift` and the plugin default at it.
3. Create the app record in App Store Connect (bundle `TME.Kelpie`, name, subtitle, category Developer Tools, age rating 4+, privacy labels: Identifiers → Device ID, linked to nothing, not used for tracking).
4. `make bump && make testflight` uploads the archive (do not use `make publish` for 1.0 without `VERSION=1.0.0`: it derives 0.1.7 from Heeler's CHANGELOG) (TestFlight is just the upload path; no tester groups). Export compliance answers: uses encryption, standard algorithms only, exempt.
5. Screenshots from the iPad itself (13" set is mandatory; 11" captures are accepted and scaled) — Anthony's hands, herdr running.
6. Submit for review with the notes and video from decision 3.

## Apple rules that bit, verified 2026-09-11

- Privacy manifest is mandatory; wrong required-reason entries are a hard rejection (ITMS-91053). Upstream's manifest ships unchanged and is believed correct.
- Age rating tiers changed July 2025 (4+/9+/13+/16+/18+); the questionnaire must be redone for a new app.
- A push device token counts as collected data (Identifiers) on the privacy label.
- Privacy Policy URL and Support URL are both mandatory.

Related: [[Open items]] · [[Heeler upstream]] · [[Feedback log]]
