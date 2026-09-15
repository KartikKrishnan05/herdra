#include <Arduino.h>
#include "LoRaWan_APP.h"
#include "HT_SSD1306Wire.h"
#include <OneWire.h>
#include <DallasTemperature.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// =====================================================
// CAMERA UART
// =====================================================

// Camera GPIO1 TX -> Heltec GPIO6 RX
// Camera GPIO2 RX <- Heltec GPIO7 TX
// Camera GND      -> Heltec GND

#define LINK_RX   6
#define LINK_TX   7
#define LINK_BAUD 115200

#define DEBUG_RX_BYTES false

HardwareSerial Link(1);

// =====================================================
// TURBIDITY SENSOR
// =====================================================

// Sensor analog output -> 10k resistor -> GPIO5 junction
// GPIO5                -> 20k resistor -> GND
// Sensor GND           -> Heltec GND

const int TURBIDITY_PIN = 5;

const float V_CLEAR = 4.29f;
const float V_DIRTY = 1.06f;

// 10k / 20k voltage divider
const float DIVIDER_FACTOR = 1.5f;

const uint16_t TURBIDITY_SAMPLES = 100;
const uint32_t SAMPLE_INTERVAL_MS = 5;
const uint32_t TURBIDITY_PAUSE_MS = 1000;

// =====================================================
// DS18B20 TEMPERATURE SENSOR
// =====================================================

// Red    -> 3.3V
// Black  -> GND
// Yellow -> GPIO19
//
// Pull-up resistor:
// 3.3V -> 5.1k -> GPIO19 / Yellow

#define ONE_WIRE_BUS 19

OneWire oneWire(ONE_WIRE_BUS);
DallasTemperature sensors(&oneWire);

bool hasTemperature = false;
float waterTemperature = 0.0f;

const uint32_t TEMP_INTERVAL_MS = 2000;
const uint32_t TEMP_CONVERSION_MS = 750;

// =====================================================
// OLED DISPLAY
// =====================================================

static SSD1306Wire display(
  0x3c,
  500000,
  SDA_OLED,
  SCL_OLED,
  GEOMETRY_128_64,
  RST_OLED
);

// =====================================================
// CAMERA READINGS
// =====================================================

bool hasReading = false;
float lastValue = 0.0f;
float lastConfidence = 0.0f;
float lastQuality = 0.0f;
bool hasConfidence = false;
bool cameraError = false;
char cameraErrorCode[16] = "";
uint32_t lastRxMs = 0;
uint32_t readingCount = 0;

// =====================================================
// TURBIDITY READINGS
// =====================================================

bool hasTurbidity = false;

float gpioVoltage = 0.0f;
float sensorVoltage = 0.0f;
float turbidity = 0.0f;

// =====================================================
// LORA: matches the supplied receiver
// =====================================================
#define RF_FREQUENCY 868000000
#define TX_OUTPUT_POWER 14
#define LORA_BANDWIDTH 0
#define LORA_SPREADING_FACTOR 7
#define LORA_CODINGRATE 1
#define LORA_PREAMBLE_LENGTH 8
#define LORA_FIX_LENGTH_PAYLOAD_ON false
#define LORA_IQ_INVERSION_ON false
#define TX_TIMEOUT_VALUE 3000

// First packet after 5 seconds; subsequent packets every 30 seconds.
const uint32_t SEND_INTERVAL_MS = 30000;
static RadioEvents_t RadioEvents;
bool transmitting = false;
uint32_t lastSendMs = 0;
uint32_t sentCount = 0;
const char *txStatus = "Ready";
// Persistent buffer remains valid until transmission completes.
char txPacket[256];

void OnTxDone() {
  Radio.Sleep();
  transmitting = false;
  sentCount++;
  txStatus = "Sent";
  Serial.printf("LoRa TX complete #%lu (no receiver acknowledgement)\n",
                (unsigned long)sentCount);
}

void OnTxTimeout() {
  Radio.Sleep();
  transmitting = false;
  txStatus = "Timeout";
  Serial.println("LoRa TX timeout; next attempt at scheduled interval");
}

void initLoRa() {
  RadioEvents.TxDone = OnTxDone;
  RadioEvents.TxTimeout = OnTxTimeout;
  Radio.Init(&RadioEvents);
  Radio.SetChannel(RF_FREQUENCY);
  Radio.SetTxConfig(
    MODEM_LORA, TX_OUTPUT_POWER, 0,
    LORA_BANDWIDTH, LORA_SPREADING_FACTOR, LORA_CODINGRATE,
    LORA_PREAMBLE_LENGTH, LORA_FIX_LENGTH_PAYLOAD_ON,
    true, 0, 0, LORA_IQ_INVERSION_ON, TX_TIMEOUT_VALUE
  );
  Radio.Sleep();
  lastSendMs = millis() - (SEND_INTERVAL_MS - 5000);
  Serial.println("LoRa ready: 868 MHz, BW125, SF7, CR4/5, CRC on");
}

void sendLoRaData() {
  const uint32_t now = millis();
  if (transmitting || now - lastSendMs < SEND_INTERVAL_MS) return;
  lastSendMs = now;

  const bool fresh = hasReading && !cameraError && now - lastRxMs < 10000;
  const bool measurable = fresh && (!hasConfidence || lastQuality > 0);
  // NA means unavailable; never substitute a made-up zero reading.
  char temp[16] = "NA", turb[16] = "NA", algae[16] = "NA";
  char confidence[16] = "NA", quality[16] = "NA", age[16] = "NA";
  if (hasTemperature) snprintf(temp, sizeof(temp), "%.2f", waterTemperature);
  if (hasTurbidity) snprintf(turb, sizeof(turb), "%.1f", turbidity);
  if (measurable) snprintf(algae, sizeof(algae), "%.2f", lastValue);
  if (fresh && hasConfidence) {
    snprintf(confidence, sizeof(confidence), "%.2f", lastConfidence);
    snprintf(quality, sizeof(quality), "%.2f", lastQuality);
  }
  if (hasReading)
    snprintf(age, sizeof(age), "%lu", (unsigned long)((now - lastRxMs) / 1000));

  // TURB is the original calibrated percentage, NOT NTU.
  // CONF is a heuristic score, NOT a calibrated probability.
  // LEVEL is unavailable: the supplied sketch has no level sensor code.
  const int length = snprintf(txPacket, sizeof(txPacket),
    "TEMP=%s,TURB=%s,LEVEL=NA,ALGAE=%s,CONF=%s,QUALITY=%s,CAM_FRESH=%d,CAM_ERR=%d,CAM_AGE=%s",
    temp, turb, algae, confidence, quality, fresh ? 1 : 0,
    cameraError ? 1 : 0, age);
  if (length <= 0 || length >= (int)sizeof(txPacket)) {
    txStatus = "Too long";
    Serial.println("LoRa packet exceeds buffer; not sent");
    return;
  }
  Serial.printf("LoRa sending (%d bytes): %s\n", length, txPacket);
  transmitting = true;
  txStatus = "Sending";
  Radio.Send((uint8_t *)txPacket, (uint8_t)length);
}

// =====================================================
// OLED SCREEN
// =====================================================

void drawScreen() {
  display.clear();
  display.setTextAlignment(TEXT_ALIGN_LEFT);
  display.setFont(ArialMT_Plain_10);
  char text[48];
  const bool fresh = hasReading && !cameraError && millis() - lastRxMs < 10000;
  if (hasReading) snprintf(text, sizeof(text), "Cov: %.1f%%%s", lastValue, fresh ? "" : " OLD");
  else snprintf(text, sizeof(text), "Coverage: --");
  display.drawString(0, 0, text);
  // * = heuristic evidence score, NOT a calibrated probability.
  if (hasReading && hasConfidence)
    snprintf(text, sizeof(text), "Conf*: %.1f%%%s", lastConfidence, fresh ? "" : " OLD");
  else snprintf(text, sizeof(text), "Conf*: --");
  display.drawString(0, 12, text);
  if (hasTurbidity) snprintf(text, sizeof(text), "Turbidity: %.1f%%", turbidity);
  else snprintf(text, sizeof(text), "Turbidity: --");
  display.drawString(0, 24, text);
  if (hasTemperature) snprintf(text, sizeof(text), "Temp: %.2f C", waterTemperature);
  else snprintf(text, sizeof(text), "Temp: --");
  display.drawString(0, 36, text);
  if (hasReading && !fresh)
    snprintf(text, sizeof(text), "Last %lus / %s",
             (unsigned long)((millis() - lastRxMs) / 1000),
             cameraError ? cameraErrorCode : "NO DATA");
  else if (!hasReading)
    snprintf(text, sizeof(text), "Camera: %s", cameraError ? cameraErrorCode : "waiting");
  else if (!hasConfidence) snprintf(text, sizeof(text), "Camera: legacy data");
  else if (lastQuality == 0) snprintf(text, sizeof(text), "UNMEASURABLE Q:0");
  else snprintf(text, sizeof(text), "View: %.0f%%%s", lastQuality,
                lastQuality < 60.0f ? " LOW" : " usable");
  // Alternate the bottom line to retain camera diagnostics and show TX status.
  if ((millis() / 3000) % 2 == 1) {
    snprintf(text, sizeof(text), "LoRa: %s #%lu", txStatus, (unsigned long)sentCount);
  }
  display.drawString(0, 48, text);
  display.display();
}

// =====================================================
// CAMERA LINE PARSER
// =====================================================

// Advance only over a finite percentage; separators checked by caller.
bool parsePercent(const char *&cursor, float &value) {
  char *end = nullptr;
  value = strtof(cursor, &end);
  if (end == cursor || !isfinite(value) || value < 0 || value > 100)
    return false;
  cursor = end;
  return true;
}

void processLine(const char *line) {
  if (strncmp(line, "E:", 2) == 0) {
    cameraError = true;
    snprintf(cameraErrorCode, sizeof(cameraErrorCode), "%.15s", line + 2);
    // Retain last successful values and timestamp. Never label them fresh.
    Serial.printf("Camera error: %s; retaining last reading\n", cameraErrorCode);
    return;
  }
  if (strncmp(line, "G:", 2) != 0) return;
  Serial.printf("Camera RX: %s\n", line);
  const char *cursor = line + 2;
  float coverage, confidence = 0, quality = 0;
  if (!parsePercent(cursor, coverage)) return;
  bool complete = false;
  // Accept legacy G:23.50 without inventing a confidence score.
  if (*cursor != '\0') {
    if (strncmp(cursor, ",C:", 3) != 0) return;
    cursor += 3;
    if (!parsePercent(cursor, confidence)) return;
    if (strncmp(cursor, ",Q:", 3) != 0) return;
    cursor += 3;
    if (!parsePercent(cursor, quality) || *cursor != '\0') return;
    complete = true;
  }
  // Commit all values together only after the whole packet validates.
  lastValue = coverage;
  lastConfidence = confidence;
  lastQuality = quality;
  hasConfidence = complete;
  hasReading = true;
  cameraError = false;
  cameraErrorCode[0] = '\0';
  lastRxMs = millis();
  readingCount++;
  Serial.printf("Coverage: %.2f%%", lastValue);
  if (complete) Serial.printf(" | Confidence* (heuristic): %.2f%% | Usable: %.2f%%",
                              lastConfidence, lastQuality);
  Serial.println();
}

// =====================================================
// CAMERA UART RECEIVER
// =====================================================

void receiveCameraData() {

  static char line[80];

  static size_t idx = 0;

  static bool discardLine = false;

  while (Link.available() > 0) {

    const int incoming =
      Link.read();

    if (incoming < 0)
      break;

    const uint8_t ch =
      (uint8_t)incoming;

    if (DEBUG_RX_BYTES) {

      Serial.printf(
        "RX byte: 0x%02X\n",
        (unsigned int)ch
      );
    }

    // End of line
    if (
      ch == '\n' ||
      ch == '\r'
    ) {

      if (
        !discardLine &&
        idx > 0
      ) {

        line[idx] = '\0';

        processLine(line);
      }

      idx = 0;

      discardLine = false;
    }

    else if (!discardLine) {

      // Reject invalid bytes
      if (
        ch < 32 ||
        ch > 126
      ) {

        Serial.println(
          "Invalid UART byte"
        );

        discardLine = true;

        idx = 0;
      }

      // Store character
      else if (
        idx < sizeof(line) - 1
      ) {

        line[idx++] =
          (char)ch;
      }

      // Line too long
      else {

        Serial.println(
          "UART line too long"
        );

        discardLine = true;

        idx = 0;
      }
    }
  }
}

// =====================================================
// NON-BLOCKING TURBIDITY
// =====================================================

void updateTurbidity() {

  static uint32_t totalMv = 0;

  static uint16_t sampleCount = 0;

  static uint32_t lastSampleMs = 0;

  static uint32_t pauseStartedMs = 0;

  static bool paused = false;

  const uint32_t now =
    millis();

  // Wait between batches
  if (paused) {

    if (
      now - pauseStartedMs <
      TURBIDITY_PAUSE_MS
    ) {

      return;
    }

    paused = false;
  }

  // Wait until next ADC sample
  if (
    now - lastSampleMs <
    SAMPLE_INTERVAL_MS
  ) {

    return;
  }

  lastSampleMs = now;

  // ADC measurement
  totalMv +=
    analogReadMilliVolts(
      TURBIDITY_PIN
    );

  sampleCount++;

  if (
    sampleCount <
    TURBIDITY_SAMPLES
  ) {

    return;
  }

  // Average ADC voltage
  gpioVoltage =
    (totalMv /
    (float)TURBIDITY_SAMPLES)
    / 1000.0f;

  // Reconstruct actual sensor voltage
  sensorVoltage =
    gpioVoltage *
    DIVIDER_FACTOR;

  // Convert voltage to turbidity %
  turbidity =
    100.0f *
    (V_CLEAR - sensorVoltage) /
    (V_CLEAR - V_DIRTY);

  // Limit 0–100 %
  if (turbidity < 0.0f)
    turbidity = 0.0f;

  if (turbidity > 100.0f)
    turbidity = 100.0f;

  hasTurbidity = true;

  Serial.printf(
    "Turbidity: %.1f%% | "
    "Sensor voltage: %.3f V\n",
    turbidity,
    sensorVoltage
  );

  // Reset averaging
  totalMv = 0;

  sampleCount = 0;

  paused = true;

  pauseStartedMs = millis();
}

// =====================================================
// NON-BLOCKING DS18B20 TEMPERATURE
// =====================================================

void updateTemperature() {

  static bool conversionRunning = false;

  static uint32_t conversionStartedMs = 0;

  static uint32_t lastTemperatureMs = 0;

  const uint32_t now =
    millis();

  // Start new measurement
  if (!conversionRunning) {

    if (
      now - lastTemperatureMs >=
      TEMP_INTERVAL_MS
    ) {

      sensors.requestTemperatures();

      conversionStartedMs = now;

      conversionRunning = true;
    }

    return;
  }

  // Wait for DS18B20 conversion
  if (
    now - conversionStartedMs <
    TEMP_CONVERSION_MS
  ) {

    return;
  }

  // Read finished conversion
  float temp =
    sensors.getTempCByIndex(0);

  conversionRunning = false;

  lastTemperatureMs = now;

  if (
    temp ==
    DEVICE_DISCONNECTED_C
  ) {

    hasTemperature = false;

    Serial.println(
      "Temperature sensor not found!"
    );

    return;
  }

  waterTemperature = temp;

  hasTemperature = true;

  Serial.printf(
    "Water temperature: %.2f C\n",
    waterTemperature
  );
}

// =====================================================
// SETUP
// =====================================================

void setup() {

  Serial.begin(115200);

  delay(100);

  Mcu.begin(HELTEC_BOARD, SLOW_CLK_TPYE);

  // ---------------------------------------------------
  // OLED
  // ---------------------------------------------------

  // Heltec Vext is active LOW
  pinMode(Vext, OUTPUT);

  digitalWrite(Vext, LOW);

  delay(100);

  display.init();

  display.clear();

  display.setTextAlignment(
    TEXT_ALIGN_LEFT
  );

  display.setFont(
    ArialMT_Plain_10
  );

  display.drawString(
    0,
    0,
    "Herdra starting..."
  );

  display.display();

  // ---------------------------------------------------
  // CAMERA UART
  // ---------------------------------------------------

  Link.begin(
    LINK_BAUD,
    SERIAL_8N1,
    LINK_RX,
    LINK_TX
  );

  // ---------------------------------------------------
  // TURBIDITY ADC
  // ---------------------------------------------------

  pinMode(
    TURBIDITY_PIN,
    INPUT
  );

  analogReadResolution(12);

  analogSetPinAttenuation(
    TURBIDITY_PIN,
    ADC_11db
  );

  // ---------------------------------------------------
  // DS18B20
  // ---------------------------------------------------

  sensors.begin();

  // VERY IMPORTANT:
  // Do not block while waiting for
  // temperature conversion.
  sensors.setWaitForConversion(false);

  int sensorCount =
    sensors.getDeviceCount();

  Serial.printf(
    "DS18B20 sensors found: %d\n",
    sensorCount
  );

  // updateTemperature() schedules and tracks each conversion.
  sensors.setResolution(12);

  initLoRa();

  // ---------------------------------------------------
  // READY
  // ---------------------------------------------------

  Serial.println();
  Serial.println(
    "=============================="
  );
  Serial.println(
    "     HERDRA WATER MONITOR"
  );
  Serial.println(
    "=============================="
  );

  Serial.println(
    "Camera    : GPIO6 RX / GPIO7 TX"
  );

  Serial.println(
    "Turbidity : GPIO5"
  );

  Serial.println(
    "Temperature: GPIO19"
  );

  Serial.println();

  delay(500);

  drawScreen();
}

// =====================================================
// MAIN LOOP
// =====================================================

void loop() {

  static uint32_t lastDrawMs = 0;

  Radio.IrqProcess();

  // Camera checked continuously
  receiveCameraData();

  // Turbidity sampling
  updateTurbidity();

  // DS18B20 temperature
  updateTemperature();

  sendLoRaData();

  // OLED refresh 4 times / second
  if (
    millis() - lastDrawMs >= 250
  ) {

    lastDrawMs = millis();

    drawScreen();
  }
}