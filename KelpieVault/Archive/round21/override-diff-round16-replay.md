# Round 21: ghostty-override-diff replayed on round 16

Command: `python3 scripts/ghostty-override-diff.py --old kelpie:kelpie-pre-rebase-20260915 --new kelpie:HEAD --kelpie-rev kelpie-pre-rebase-20260915 --no-fetch` at `81022a1`, 2026-09-15. The three compile-time collisions round 16 hit are the COLLISION and CONFORMANCE rows; the BODY rows are the six upstream implementations that changed under a Kelpie `super` call and one Kelpie replaces outright.

```
GhosttyTerminal override-point diff
  old: kelpie kelpie-pre-rebase-20260915 (fd42c5c)
  new: kelpie HEAD (23d1d5c)
  Kelpie: HeelerTerminalView, TerminalThemePreviewView (kelpie-pre-rebase-20260915) — 45 override point(s), 231 own member(s), 6 conformance(s)

17 finding(s) to read before the build:
  - [BODY] canPerformAction(_:withSender:): upstream's implementation changed (Platform/UIKit/UITerminalView+Interaction.swift:374 → Platform/UIKit/UITerminalView+Clipboard.swift:58); Kelpie calls super here
  - [BODY] contextMenuInteraction(_:configurationForMenuAtLocation:): upstream's implementation changed (Platform/UIKit/UITerminalView+Interaction.swift:736 → Platform/UIKit/UITerminalView+Clipboard.swift:73); Kelpie calls super here
  - [BODY] copy(_:): upstream's implementation changed (Platform/UIKit/UITerminalView+Interaction.swift:350 → Platform/UIKit/UITerminalView+Clipboard.swift:10); Kelpie calls super here
  - [BODY] deleteBackward(): upstream's implementation changed (Platform/UIKit/UITerminalView+UITextInput.swift:144 → Platform/UIKit/UITerminalView+UITextInput.swift:149); Kelpie calls super here
  - [BODY] didMoveToWindow(): upstream's implementation changed (Platform/UIKit/UITerminalView+Lifecycle.swift:66 → Platform/UIKit/UITerminalView+Lifecycle.swift:66); Kelpie calls super here
  - [BODY] keyCommands: upstream's implementation changed (Platform/UIKit/UITerminalView+Keyboard.swift:110 → Platform/UIKit/UITerminalView+KeyCommands.swift:83); Kelpie calls super here
  - [BODY] paste(_:): upstream's implementation changed (Platform/UIKit/UITerminalView+Interaction.swift:363 → Platform/UIKit/UITerminalView+Clipboard.swift:24); Kelpie replaces it without super, so behaviour Kelpie skips may have moved
  - [BODY] resignFirstResponder(): upstream's implementation changed (Platform/UIKit/UITerminalView+Lifecycle.swift:218 → Platform/UIKit/UITerminalView+Lifecycle.swift:259); Kelpie calls super here
  - [BODY] touchesEnded(_:with:): upstream's implementation changed (Platform/UIKit/UITerminalView+Interaction.swift:90 → Platform/UIKit/UITerminalView+Interaction.swift:73); Kelpie calls super here
  - [COLLISION] dropInteraction(_:canHandle:): Kelpie declares it at Terminal/TerminalScreenView.swift:3349 without override; upstream now has public func dropInteraction(_:canHandle:) (Platform/UIKit/UITerminalView+Drop.swift:24)
  - [COLLISION] dropInteraction(_:performDrop:): Kelpie declares it at Terminal/TerminalScreenView.swift:3370 without override; upstream now has public func dropInteraction(_:performDrop:) (Platform/UIKit/UITerminalView+Drop.swift:36)
  - [COLLISION] dropInteraction(_:sessionDidUpdate:): Kelpie declares it at Terminal/TerminalScreenView.swift:3363 without override; upstream now has public func dropInteraction(_:sessionDidUpdate:) (Platform/UIKit/UITerminalView+Drop.swift:32)
  - [NAME CLASH] gestureRecognizer(_:shouldReceive:) vs upstream's new public func gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:) (Platform/UIKit/UITerminalView+Pointer.swift:406) (Kelpie at Terminal/TerminalScreenView.swift:2017)
  - [COLLISION] gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:): Kelpie declares it at Terminal/TerminalScreenView.swift:2026 without override; upstream now has public func gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:) (Platform/UIKit/UITerminalView+Pointer.swift:406)
  - [COLLISION] handleEscapeKeyCommand(_:): Kelpie declares it at Terminal/TerminalScreenView.swift:2582 without override; upstream now has private func handleEscapeKeyCommand(_:) (Platform/UIKit/UITerminalView+KeyCommands.swift:120)
  - [CONFORMANCE] UIDropInteractionDelegate: upstream now conforms UITerminalView (Platform/UIKit/UITerminalView+Drop.swift:19); Kelpie's own conformance at Terminal/TerminalScreenView.swift:3348 is redundant and its members collide
  - [API SIGNATURE] TerminalSurface.sendMousePos(x:y:modifiers:)
      old: public func sendMousePos(x: Double, y: Double, modifiers: TerminalInputModifiers)
      new: public func sendMousePos(x: Double, y: Double, modifiers: TerminalInputModifiers = [])

Context:
  - shadow: Kelpie's escapeKeyCommands (Terminal/TerminalScreenView.swift:2564) now has an invisible upstream twin, private let escapeKeyCommands (Platform/UIKit/UITerminalView+KeyCommands.swift:55)
  - upstream UITerminalView newly conforms to UIPointerInteractionDelegate (Platform/UIKit/UITerminalView+Pointer.swift:415)
  - API body changed: InMemoryTerminalSession.finish(exitCode:runtimeMilliseconds:) (InMemory/InMemoryTerminalSession.swift:205)
  - API body changed: InMemoryTerminalSession.readViewportText() (InMemory/InMemoryTerminalSession.swift:113)
  - API body changed: UITerminalView.configuration (Platform/UIKit/UITerminalView.swift:93)
  - upstream added 33 UITerminalView member(s): applyMouseShape(_:), cancelReportedPointerButton(at:), claimKeyCommandDelivery(input:modifierFlags:), dropInteraction(_:canHandle:), dropInteraction(_:performDrop:), dropInteraction(_:sessionDidUpdate:), escapeKeyCommands, fallbackDisplayScale, gameControllerPointerMods(), gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:), handleEscapeKeyCommand(_:), handlePointerHover(_:), handleScrollWheelGesture(_:), isMouseCaptured, keyCommandInput(for:filteredModifierFlags:), notePointerModifierFlags(_:), paste(text:), pasteFromPasteboard(), pointerInteraction(_:styleFor:), pointerMods(), refreshPointerPositionForModifierChange(), sendKey(_:), sendKey(_:modifiers:), sendMouseButton(state:button:modifiers:), sendMousePos(x:y:modifiers:), sendMouseScroll(x:y:mods:), sendPointerPosition(at:remember:), sendSyntheticRelease(for:), sendTapClick(at:), setupDropInput(), snapshotImage(), sublayerFrame, toggleSoftwareKeyboard()
  - upstream removed 4 UITerminalView member(s): claimControlKeyDelivery(input:modifierFlags:), handleCatalystScrollWheelGesture(_:), pointIsInsidePointerSelection(_:), setupCatalystScrollWheelInput()
  - Platform/UIKit/ added InputAccessory/TerminalInputAccessoryStyle.swift, InputAccessory/TerminalInputAccessoryView.swift, InputAccessory/TerminalInputBarKey.swift, InputAccessory/TerminalStickyModifierState.swift, InputAccessory/UITerminalView+InputAccessory.swift, InputAccessory/UITerminalView+PublicSticky.swift, UITerminalView+Clipboard.swift, UITerminalView+Drop.swift, UITerminalView+KeyCommands.swift, UITerminalView+Pointer.swift, UITerminalView+Scroll.swift, UITerminalView+Snapshot.swift; removed TerminalInputAccessoryStyle.swift, TerminalInputAccessoryView.swift, TerminalInputBarKey.swift, TerminalStickyModifierState.swift, UITerminalView+InputAccessory.swift, UITerminalView+PublicSticky.swift; changed TerminalTextInputHandler@UIKit.swift, UITerminalView+Interaction.swift, UITerminalView+Keyboard.swift, UITerminalView+Lifecycle.swift, UITerminalView+PinchZoom.swift, UITerminalView+PublicInput.swift, UITerminalView+UITextInput.swift, UITerminalView.swift
  - Platform/Shared/ added TerminalFileStaging.swift, TerminalPasteboardContent.swift, TerminalPointerPolicy.swift, TerminalShellEscape.swift; changed TerminalHardwareKeyRouter.swift, TerminalMainActor.swift, TerminalView+Process.swift
  - Surface/ added TerminalKey.swift, TerminalKeyPress.swift; changed TerminalSelectionAnchor.swift, TerminalSurface.swift, TerminalSurfaceCoordinator.swift, TerminalSurfaceView.swift, TerminalSurfaceViewDelegate.swift
```

The live case the same day, the vendored `7e45d27` against upstream `main` (`ba99078`, "Pin Ghostty 0c2a290d"): no override point, collision, conformance or public API Kelpie relies on changed; exit 0.
