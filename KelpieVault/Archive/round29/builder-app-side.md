# Open item 42, app side — done

- NotificationRegistrationFile.swift: added `upserting(_:replacing:)`; `upserting(_:)` now calls it with nil. Type doc comment updated.
- NotificationRegistrationCeremony.swift: `register(..., replacing:)`, passes `previousToken?.hex`; doc updated.
- NotificationPreferencesStore.swift: `reregisterIfPairChanged` passes `replacing: last`; `setNotificationsEnabled` enable branch passes the last recorded token too. `setDoneEnabled` left alone (guarded on isRegistered under the current token).
- Tests: 4 cases in NotificationRegistrationFileTests, 1 in NotificationRegistrationCeremonyTests.
- BUILD SUCCEEDED and TEST BUILD SUCCEEDED (generic/platform=iOS, fixed derived data path).
