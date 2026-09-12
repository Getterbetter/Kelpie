# Round 13 post texts, 2026-09-13

## r/herdr — standalone post (drafted 08:15, yes on the text, posted 08:45: https://www.reddit.com/r/herdr/comments/1wepr2j/)

**Title:** Kelpie: herdr's own TUI on the iPad and iPhone over SSH, a fork of Heeler (free, open source, TestFlight)

**Body:**

I mentioned an iPad version under the Heeler thread; here it is properly. Kelpie shows herdr itself on the iPad and iPhone: the real TUI over SSH, full screen, not a mobile dashboard with its own ideas about your sessions. Same herdr, different screen.

It is a fork of Heeler, and Heeler deserves the credit for the hard part: SSH straight onto the herdr socket, pairing, the push plugin and the encrypted notification relay are all Heeler's work and still the engine underneath. If you have not, go and star it.

What I added is the screen and the input layer. herdr's own interface instead of a native console. Escape and Cmd+. reach herdr from a Magic Keyboard, a trackpad right-click opens herdr's menu, a long press does the same by touch, hold and drag resizes panes, touch selection with handles, and a key row above the software keyboard for esc, tab, ctrl and arrows. You can paste a photo straight into a Claude pane; it is staged over SFTP and the path typed in. Push notifications when an agent is waiting on you. On the phone herdr's own mobile layout takes over below 64 columns. Pair once and the pairing syncs through iCloud Keychain, so the iPhone is ready without pairing again.

Security, since it is an app SSH-ing into your dev box: the SSH key is generated on the device and never leaves the Keychain, host keys are pinned on first use, and the relay only ever sees ciphertext.

Free, Apache 2.0 like Heeler, credited in the app and the repo. TestFlight: https://testflight.apple.com/join/AkJxAbnJ. Source: github.com/Getterbetter/Kelpie. I'm the developer; bugs to r/KelpieConsole so they stay out of this sub. Anything from the iPad work that is useful upstream, I'm glad to send.
