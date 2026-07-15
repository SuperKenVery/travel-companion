# TcNotificationsApple

Private UserNotifications backend. Reusing a notification identifier implements coalescing.
Starting installs the backend as `UNUserNotificationCenterDelegate`, so notification presentation
and user actions are returned as module events.

Commands use `type` and `requestID?`: `start`, `requestAuthorization`, `settings`, `removeAll`;
`remove` adds `identifier?` or `identifiers?`; `schedule` adds `identifier`, `title?`, `subtitle?`,
`body?`, `categoryIdentifier?`, `threadIdentifier?`, `sound?`, `badge?`, `delayMillis?`,
`repeats?`, and string-to-string `userInfo?`. With no delay it is delivered immediately.

Every event has
`{"type":String,"requestID":String?,"identifier":String?,"actionIdentifier":String?,`<br>
`"userInfo":{String:String}?,"fields":{String:String}?,"error":String?}`. Stable types are
`commandCompleted`, `commandFailed`, `authorizationResult`, `capabilitySnapshot`,
`notificationScheduled`, `notificationPresented`, `notificationResponse`, and
`notificationsRemoved`. The app must bootstrap this backend early enough to receive responses.
