# Approved post texts, 2026-09-12 (Anthony: "5- do it . 3- good")

## r/SideProject — reply to u/Training_Mail_973 (comment t1_p9bp6zo)
https://www.reddit.com/r/SideProject/comments/1we8kte/comment/p9bp6zo/

Thanks! The photo never goes through the terminal as pixels; it is staged as a file. Kelpie decodes the paste into a bounded image (long edge capped at 4096 px), bakes in the orientation, strips the metadata by re-encoding from pixels, and steps the JPEG quality down until it is under 16 MB. It then SFTPs that file to a temp path on the Mac and types the path into the Claude pane, so Claude reads it locally like any other file. That pipeline is Heeler's work; I wired the paste, drop and menu routes into herdr's pane.

## r/ClaudeCode — weekly showcase thread, one comment
Text: the "r/ClaudeCode" variant in `~/MemoryOS/Areas/Marketing/Kelpie/Drafts - Beta announcement - 2026-09-12.md`.

## r/herdr — reply under Anthony's own comment on the Heeler author's thread (drafted, awaiting his yes)
https://www.reddit.com/r/herdr/comments/1vxsh7w/comment/p8x6wak/

Here it is: Kelpie, a fork of Heeler for the iPad and iPhone. Instead of a native console it puts herdr's own TUI on the screen over SSH, full screen, with the input layer done for the Magic Keyboard, trackpad and touch: Escape and Cmd+. reach herdr, a right-click opens herdr's menu, hold-and-drag resizes panes, and you can paste a photo straight into a Claude pane. Pairing, push and the encrypted relay are Heeler's engine underneath, and pairing now syncs between devices over iCloud Keychain. Free and open source under Heeler's Apache licence, credited in the app and the repo. TestFlight: https://testflight.apple.com/join/AkJxAbnJ. Source: github.com/Getterbetter/Kelpie. Thanks u/zingerlittlebee for the foundation; anything from the iPad work that is useful upstream, I'm glad to send.

## r/ClaudeAI — Showcase post: HELD until Anthony has commented there for a few days.
