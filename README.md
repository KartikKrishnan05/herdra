# HERDRA

Floating water-quality monitors for livestock water troughs, with a LoRa link to the farmhouse and an iPhone app that tells the farmer which trough needs attention.

Built by a team of five during the two-week **THINK. MAKE. START.** makeathon at UnternehmerTUM: a solar-powered prototype for remote livestock farms covering sensors, firmware, a mobile app and a business case.

Each floating station measures **water level, turbidity, temperature and algae coverage**, sends a compact LoRa packet every 30 seconds, and a receiver at the house serves the data over its own Wi-Fi. The iOS app (TroughWatch) turns raw readings into a simple *all good / keep an eye on it / needs attention* status per trough, on a map.

```
 ┌──────────────── floating station ────────────────┐
 │  ESP32-S3 camera ──UART──▶ Heltec LoRa 32 V3       │          ┌────────── farmhouse ──────────┐
 │  (algae colour         + pressure level sensor     │  LoRa    │  Heltec LoRa 32 V3            │   Wi-Fi    ┌──────────────┐
 │   analysis on-board)   + turbidity sensor          │ ───────▶ │  Wi-Fi AP "HERDRA-RX"         │ ─────────▶ │  TroughWatch │
 │                        + DS18B20 temperature       │  868 MHz │  JSON at 192.168.4.1/data     │  HTTP poll │  (iOS app)   │
 └───────────────────────────────────────────────────┘          └───────────────────────────────┘            └──────────────┘
```

## Components

| Folder | Hardware | What it does |
| --- | --- | --- |
| [`cam_green_uart/`](cam_green_uart) | ESP32-S3 camera module | Switches on a flash LED, captures a frame and estimates the share of algae-coloured pixels (HSV thresholds). Sends coverage, confidence and image quality to the sender over UART. An image doesn't fit in a LoRa packet, so the analysis happens on the camera. |
| [`heltec_display_value/`](heltec_display_value) | Heltec WiFi LoRa 32 V3 | The sender. Samples the level and turbidity sensors (raw mV), the DS18B20 and the camera over several rounds, takes the median of each, and transmits one line per cycle at 868 MHz. Shows the current values on the OLED. |
| [`herdra_receiver_ap/`](herdra_receiver_ap) | Heltec WiFi LoRa 32 V3 | The receiver. Opens a Wi-Fi access point, keeps the last 50 packets with RSSI/SNR, and serves them at `/data` (JSON) and `/csv`. Reachable at `192.168.4.1` or `herdra.local`. |
| [`herdra_dashboard/`](herdra_dashboard) | iPhone (iOS 17+) | **TroughWatch**, a SwiftUI app: pins each trough on a map, converts raw readings with per-trough calibration, keeps a week of history, and decides the status from trends rather than single readings. See its [README](herdra_dashboard/README.md) for the full details. |

## Packet format

The sender does no interpretation; calibration lives in the app so it can be changed without reflashing.

```
TEMP=18.25,LVL_MV=258.0,TURB_MV=2500.0,ALGAE=4.10,CONF=12.00,QUALITY=88.00,
CAM_FRESH=1,CAM_ERR=0,CAM_AGE=7,N_LVL=3,N_TURB=3,N_TEMP=3,N_CAM=2,BATCH=42
```

## Getting started

**Firmware** (Arduino IDE or `arduino-cli`):

1. Install the [Heltec ESP32 board package](https://github.com/HelTecAutomation/Heltec_ESP32) and the `OneWire` and `DallasTemperature` libraries.
2. Flash `heltec_display_value` to the station's Heltec board and `herdra_receiver_ap` to the receiver's.
3. Flash `cam_green_uart` to the ESP32-S3 camera board (set PSRAM to "OPI PSRAM" in the board settings).
4. Wiring is documented at the top of each sketch (sensor GPIOs, the 10k/20k divider on the turbidity line, camera UART on GPIO 6/7).

**App:**

```bash
cd herdra_dashboard
open TroughWatch.xcodeproj
```

Join the `HERDRA-RX` Wi-Fi on the iPhone, then run the app. The receiver's default password is set in `herdra_receiver_ap.ino`; change it before deploying.

## Status

Working prototype. The alarm thresholds and sensor calibration are first guesses and still need validating on real troughs.
