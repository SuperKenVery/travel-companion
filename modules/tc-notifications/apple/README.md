# TcNotificationsApple

Private UserNotifications backend. Reusing a merge key implements coalescing. Construction installs
the backend as `UNUserNotificationCenterDelegate`, so user actions return to the module; shutdown
restores the prior delegate. Cold-start lifecycle code can pass string `userInfo` to
`handleNotificationResponse(userInfo:)` so notification opens use the same semantic event path.

The public capability boundary is typed. The backend exposes `requestAuthorization`, `schedule`,
and `cancel` methods and emits `TcNotificationsEvent` values through its event sink;
`TcNotificationAuthorization` represents the platform authorization state. Semantic identifiers
and deep links remain ordinary strings across the boundary. No command/event JSON or
`UserNotifications` object crosses it.
