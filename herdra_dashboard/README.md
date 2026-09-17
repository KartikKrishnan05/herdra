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
  Models/Models.swift       Coordinate, WaterStatus, Reading, Trough, HomeBase
  Models/History.swift      Sample, Metric, keeping a week, medians and slopes
  Models/Assessment.swift   the rules: good / watch / act now, from the history
  Models/SensorCalibration.swift  raw mV → depth (cm) and turbidity (%)
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

**The map.** "Show all troughs" at the bottom of the map zooms out until home
and every trough are in view. `MapScreen` also recomputes a bounding box over the home point and every
trough each time one is added, so the view widens by itself as the farm fills up.
`MapFitter.region(for:)` pads the box by 50% and clamps it between roughly 350 m
and a few kilometres across.

**Red highlighting.** A trough's pin takes the colour of its status, and bad
(red) or check (orange) troughs also get a filled ring drawn around them with
`MapCircle`, sized relative to how spread out the troughs are. Tap a pin for a
card at the bottom; tap through for the full detail screen.

**Reading the receiver.** The Heltec receiver runs its own Wi-Fi access point,
`HERDRA-RX` (password `herdra1234`), and serves its last 50 LoRa packets as JSON
at `http://192.168.4.1/data`. Join that network in the iPhone's Settings. The app
polls `/data` every two seconds and parses each packet's raw line itself
(`LoRaMessage.reading(from:)`), since no server sits in between any more. RSSI
and SNR come from the receiver.

Settings → Receiver shows the address (default `192.168.4.1`; `herdra.local`
also works), whether the feed is coming through, and the receiver's packet
count, uptime and connected phones.

**Storage.** `TroughStore` writes home + troughs to
`Documents/troughwatch-state.json` on every change, and every trough's history to
`Documents/troughwatch-history.json` at most every 30 seconds and when the app goes
to the background. History covers a week: the last day packet by packet, older
readings merged into 10-minute medians. The receiver address lives in
UserDefaults. Nothing is uploaded anywhere.

The phone only hears packets while it is on `HERDRA-RX`, and the receiver holds its
last 50, so history has gaps when nobody is at the receiver. The assessment copes
with gaps, but the more often a phone joins, the better the trends.

**The trough screen.** Written for the farmer: a big status ("All good", "Keep an
eye on it", "Needs attention"), a "What to do" list in plain sentences, four tiles
(water level, algae, clarity, temperature) with a word and a trend arrow, and a
hour/day/week chart (the hour shows every batch) with dashed orange/red limit lines. "I cleaned this trough" makes
the assessment ignore readings from before the cleaning. Location, device ID and
removing the trough are under Device settings.

**Developer tab.** Always shown while this is a prototype: the receiver's
live packet buffer as sent, and per trough the last packet's raw values (mV,
°C, camera numbers, valid rounds, batch), what the app converted them to, what
the farmer is shown, the stored readings, and the calibration editor.

**Only real readings.** The app has no made-up data. Everything stored came from
the receiver. Developer tab → Clear readings forgets stored readings (the
receiver's last 50 packets come back on the next poll). The first launch of this
version clears readings once, to remove the example week older builds could add.

## How the feed maps onto troughs

Every packet in the receiver's buffer is routed in
`TroughStore.apply(_:preferring:)` and added to that trough's history:

1. A device ID in the LoRa line. `LoRaMessage.deviceID(in:)` looks for `ID=`,
   `DEV=`, `DEVICE=`, `NODE=` or `STATION=` and matches it against each trough's
   device ID. Have each sender include one and several troughs work at once.
2. The trough picked under Settings → Station.
3. Failing both, the first active trough.

A packet within 10 seconds of the last one stored for that trough is the same
packet seen again, and is skipped (the sender waits at least 30 s between packets).

## What the sender sends, and who converts it

The sender does no interpretation. After five rounds it sends the median of each
sensor's raw value:

```
TEMP=18.25,LVL_MV=258.0,TURB_MV=2500.0,ALGAE=4.10,CONF=12.00,QUALITY=88.00,
CAM_FRESH=1,CAM_ERR=0,CAM_AGE=7,N_LVL=5,N_TURB=4,N_TEMP=5,N_CAM=3,BATCH=42
```

- `LVL_MV`, `TURB_MV` — millivolts at GPIO3 / GPIO4 (turbidity is after the 10k/20k divider).
- `TEMP` — °C from the DS18B20, which is what that sensor reports.
- `ALGAE`, `CONF`, `QUALITY` — from the camera's on-board image analysis (an
  image doesn't fit in a LoRa packet, so this stays on the camera).
- `N_*` — valid rounds out of 5 per sensor; `BATCH` — sender batch number.

The app turns `LVL_MV` into cm, `TURB_MV` into % and the camera's `ALGAE` into
algae coverage with the trough's `SensorCalibration`. Prototype defaults:

- Level: 116 mV dry, 372 mV = 18 cm (linear, never below 0).
- Algae: camera `ALGAE` 10 % (clean, silver surface) = 0 % coverage, 40 % (fully
  covered) = 100 %, linear and clamped. The algae limits below apply to coverage.
- Turbidity: 4.29 V clear, 1.06 V dirty at the sensor, divider factor 1.5. Samples keep their raw mV, so saving a new calibration on the
Developer tab recalculates the whole history. Packets from older firmware that
send `LEVEL=` / `TURB=` already converted are still accepted as they are.

## Deciding good, watch and act now

`Assessment` in `Assessment.swift` is the only place that decides a colour. It
never judges a trough on one packet. It looks at the stored history since the
trough was last cleaned:

- **Now** for water level and algae is the median of the newest three batches, so
  two batches in a row that agree show at once and one odd batch is ignored.
  Clarity and temperature use a median over the last hour.
- **Trends** are slopes through hourly medians, over hours (level) or days
  (algae, temperature, clarity).
- **Algae** only counts camera readings without an error and with quality ≥ 50.

| Thing | Act now | Watch |
| --- | --- | --- |
| Water level | below 35 % of full | below 65 % of full, or falling ≥ 10 % of full per hour for a few hours |
| Algae (coverage) | ≥ 80 % in two of the last three batches | ≥ 40 % in two of the last three batches; below 40 % is always fine |
| Clarity (`TURB`, %) | ≥ 60 % | ≥ 30 % |
| Temperature | ≤ 0.5 °C | below 3 °C or ≥ 25 °C |
| Device | — | camera failing on most packets in the last hour, or quality below 50 |

"Full" is each trough's water depth when full, set under Settings → Water depth
when full (default 18 cm, e.g. very low below 6.3 cm and getting low below 11.7 cm).

The worst of these sets the trough's colour. After 24 hours without a packet the
trough shows "No recent news" instead of an old colour. Change a threshold there
and the list, the map and the trough screen all follow. These limits are first
guesses and still need checking against real troughs.

Turbidity is a 0–100 % value from the app's calibration, not NTU, and level is a
depth in centimetres, not a percentage.

## What the station doesn't send

`Reading` mirrors the feed exactly, which means there is no pH and no device
battery — the LoRa line carries neither, so the app no longer claims to show
them. If the firmware gains a `BATT=` key, it is a field on `Reading`, a line in
`LoRaMessage.reading(from:)` and a row on the Developer tab.

Still worth adding: a local notification when a trough turns red.
