# LocationApple

Core Location implementation of the typed `location` contract. Each command is a public method;
events use `LocationEvent`, `LocationAuthorization`, and `LocationSample`. No Core Location
object or private Apple schema crosses the module boundary.

Accepted commands are `startTravelUpdates`, `stopTravelUpdates`, and `requestSample`. Emitted
events are `started`, `stopped`, `authorizationChanged`, `sample`, `timedOut`, and `failed`,
using the fields from `LocationCommand`, `LocationEvent`, and `LocationSample` directly.

An active trip owns its `CLServiceSession`, optional `CLBackgroundActivitySession`, diagnostic
streams, and `CLLocationUpdate.liveUpdates`. Every valid callback updates the cache; outbound
updates are distance/time throttled, with a longer interval while stationary. An on-demand request
uses a sufficiently fresh cache or races a live update against `deadlineMs`.

There is no module-specific C ABI or public header. Swift constructs the main-actor backend and
forwards typed events through the supplied event sink.
