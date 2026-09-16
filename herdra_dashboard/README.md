# TroughWatch

An iOS app for keeping track of floating water-quality devices, one per water trough.

You save the house once, then add a trough each time you drop a device in the
water, and the map grows to cover all of them. The app reads live measurements
straight from the HERDRA LoRa receiver over its own Wi-Fi.

## Running it

Open `TroughWatch.xcodeproj` and hit Run — the project, the Info.plist keys and the
asset catalog are all in place, so there is nothing to configure first.

From the command line:

```sh
xcodebuild -project TroughWatch.xcodeproj -scheme TroughWatch \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

A few things worth knowing:

- Deployment target is **iOS 17.0** — the map code uses the iOS 17 MapKit API.
- The simulator has no GPS until you give it one: Features → Location → Custom
  Location, or `xcrun simctl location booted set <lat>,<lon>`. Without a fix the
  "Save this as home" button stays disabled.
- On a real device, set your own team under Signing & Capabilities first; the
  bundle ID ships as `com.example.TroughWatch`.
- Location and local-network usage strings are set as `INFOPLIST_KEY_*` build
  settings. The checked-in `Info.plist` holds only the one key that has no
  build-setting equivalent — the App Transport Security exception that lets the
  app talk plain HTTP to a server on the farm's own network. Xcode merges the
  two, so the usage strings still live in build settings.

## Layout

```
TroughWatch/
  TroughWatchApp.swift      app entry + RootView
  Models/Models.swift       Coordinate, WaterStatus, Reading, StatusRule,
                            Trough, HomeBase
  Services/                 TroughStore (state + persistence), LocationManager,
                            ReceiverFeed (the Heltec /data client)
  Views/                    setup, list, map, add, detail, settings
  Assets.xcassets/          AppIcon (placeholder), AccentColor
```

The target uses a synchronized folder group, so a new `.swift` file dropped into
`TroughWatch/` is picked up on the next build — no need to add it to the project.

## How it works

**Setup (once, at the house).** `HomeSetupView` asks for location permission and
saves the home point. Everything after that is measured from here, and the app
skips this screen on every later launch.

**Adding a trough.** Tab "Troughs" → `+`, or the `+` on the map. Stand at the
trough, and "Save location and add device" pins the current GPS position, gives
the device a name and an ID, and puts it in the active list. Name and ID are
pre-filled (`Trough 3`, `DEV-003`) so you can add one with two taps in the rain.

**The map.** `MapScreen` recomputes a bounding box over the home point and every
trough each time one is added, so the view widens by itself as the farm fills up.
`MapFitter.region(for:)` pads the box by 50% and clamps it between roughly 350 m
and a few kilometres across. "Fit all" in the toolbar re-frames it manually.

**Red highlighting.** A trough's pin takes the colour of its status, and bad
(red) or check (orange) troughs also get a filled ring drawn around them with
`MapCircle`, sized relative to how spread out the troughs are. Tap a pin for a
card at the bottom; tap through for the full detail screen.

**Storage.** `TroughStore` writes home + troughs to
`Documents/troughwatch-state.json` on every change. No server, no account.

**Reading the receiver.** The Heltec receiver runs its own Wi-Fi access point,
`HERDRA-RX` (password `herdra1234`), and serves its last 50 LoRa packets as JSON
at `http://192.168.4.1/data`. Join that network in the iPhone's Settings. The app
polls `/data` every two seconds and parses each packet's raw
`TEMP=..,TURB=..,LEVEL=..` line itself (`LoRaMessage.reading(from:)`), since
no server sits in between any more. RSSI and SNR come from the receiver.

Settings → Receiver shows the address (default `192.168.4.1`; `herdra.local`
also works), whether the feed is coming through, and the receiver's packet
count, uptime and connected phones.

**Storage.** `TroughStore` writes home + troughs to
`Documents/troughwatch-state.json` on every change. The receiver address lives in
UserDefaults. The packet history is kept in memory only, like the receiver's own
buffer. Nothing is uploaded anywhere.

**Standing in for the receiver.** Settings → "Fake a round of readings" gives
every active trough a made-up packet, judged by the same rules as a real one, so
you can watch the colours and counts change with nothing on the network.

## How the feed maps onto troughs

Each polled packet is routed in `TroughStore.apply(_:preferring:)`, newest packet
per device first:

1. A device ID in the LoRa line. `LoRaMessage.deviceID(in:)` looks for `ID=`,
   `DEV=`, `DEVICE=`, `NODE=` or `STATION=` and matches it against each trough's
   device ID. Have each sender include one and several troughs work at once.
2. The trough picked under Settings → Station.
3. Failing both, the first active trough.

A packet that's already been applied is skipped, so a status set by hand holds
until a new packet actually arrives.

## Deciding good, check and bad

`StatusRule` in `Models.swift` is the only place that decides a colour, and its
tests are the web dashboard's alert banner in the same order:

| Test | Result |
| --- | --- |
| camera error code is not 0 | bad — camera system error |
| quality below 50 | bad — poor measurement quality |
| turbidity above 500 NTU | bad — water turbidity is very high |
| water level below 10 cm | bad — water level is critically low |
| water level missing | check — level measurement unavailable |
| otherwise | fine |

A packet with no measurements at all reads as "no data" rather than fine. Change
a threshold here and the list, the map and the detail screen all follow.

Note that `LEVEL` is a depth in centimetres, not a percentage — the reading field
is `waterLevelCM` to keep that straight.

## What the station doesn't send

`Reading` mirrors the feed exactly, which means there is no pH and no device
battery — the LoRa line carries neither, so the app no longer claims to show
them. If the firmware gains a `BATT=` key, it is a field on `Reading`, a line in
`LoRaMessage.reading(from:)` and a row in the detail screen.

Still worth adding: a "last heard from" timeout that flips a trough back to
unknown after a few hours of silence, and a local notification when one turns
red.
