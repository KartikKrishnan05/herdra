#include <Arduino.h>
#include "LoRaWan_APP.h"
#include "HT_SSD1306Wire.h"
#include <OneWire.h>
#include <DallasTemperature.h>
#include <esp_system.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

// HELTEC WIFI LORA 32 V3
// Pressure converter OUT -> GPIO3; converter GND -> Heltec GND.
// Turbidity OUT -> 10k -> GPIO4; GPIO4 -> 20k -> GND.
// DS18B20 data -> GPIO19, with 4.7k-5.1k pull-up to 3.3V.
// DS18B20 supply -> 3.3V, GND -> GND. GPIO22 does NOT exist on ESP32-S3.
// Camera GPIO1 TX -> Heltec GPIO6 RX.
// Camera GPIO2 RX <- Heltec GPIO7 TX. Common GND required.
// Sensors remain powered. Scheduling is NOT power switching.
// Flash off / camera awaiting commands does not mean camera power is off.

const int LEVEL_PIN = 3;
const int TURBIDITY_PIN = 4;
const int ONE_WIRE_BUS = 19;
const int LINK_RX = 6, LINK_TX = 7;
const uint32_t LINK_BAUD = 115200;

// No calibration here: the sender reports raw millivolts at the ADC pins and
// the TroughWatch app turns them into depth (cm) and turbidity (%), using a
// calibration stored per trough in the app (Developer tab).
// TURB_MV is measured at GPIO4, i.e. AFTER the 10k/20k divider.

// Five complete rounds, then median across the valid round results.
// A minimum of 3 valid results per sensor is required.
const uint8_t ROUNDS = 3, MIN_VALID = 2;
const uint16_t ADC_SAMPLES = 50;
const uint32_t ADC_INTERVAL_MS = 5;
const uint32_t SETTLE_MS = 200;
const uint32_t CAMERA_TIMEOUT_MS = 15000;
const uint32_t SYNC_RETRY_MS = 3000;
// Minimum start-to-start cycle period; never overlap cycles.
const uint32_t CYCLE_INTERVAL_MS = 30000;

#define RF_FREQUENCY 868000000
#define TX_OUTPUT_POWER 14
#define LORA_BANDWIDTH 0
#define LORA_SPREADING_FACTOR 7
#define LORA_CODINGRATE 1
#define LORA_PREAMBLE_LENGTH 8
#define TX_TIMEOUT_VALUE 3000

HardwareSerial Link(1);
OneWire oneWire(ONE_WIRE_BUS);
DallasTemperature sensors(&oneWire);
static SSD1306Wire display(
  0x3c, 500000, SDA_OLED, SCL_OLED, GEOMETRY_128_64, RST_OLED
);
static RadioEvents_t RadioEvents;

enum Stage {
  WAIT_CYCLE, SYNC_CAMERA, LEVEL_SETTLE, LEVEL_SAMPLE,
  TURB_SETTLE, TURB_SAMPLE, TEMP_READ, CAMERA_WAIT, TX_WAIT
};
void changeStage(Stage next); // Explicit prototype for Arduino sketch preprocessing.
Stage stage = WAIT_CYCLE;
uint32_t stageMs = 0, cycleMs = 0, sampleMs = 0;
uint32_t requestId = 0, activeId = 0, batchId = 0;
uint32_t sentCount = 0, lastDisplayMs = 0;
uint8_t roundIndex = 0;
bool firstCycle = true, recovering = false, transmitting = false;
bool cameraHadError = false;
const char *txStatus = "Ready";
char txPacket[256];
uint16_t adcSamples[ADC_SAMPLES];
uint16_t adcCount = 0;

float levelRounds[ROUNDS], turbRounds[ROUNDS], tempRounds[ROUNDS];
float algaeRounds[ROUNDS], confRounds[ROUNDS], qualityRounds[ROUNDS];
float resultLevelMV = NAN, resultTurbMV = NAN, resultTemp = NAN;
float resultAlgae = NAN, resultConf = NAN, resultQuality = NAN;
uint8_t nLevel = 0, nTurb = 0, nTemp = 0, nCamera = 0;
bool hasBatch = false;
uint32_t lastCameraMs = 0;

float median(float *values, uint16_t count) {
  if (!count) return NAN;
  for (uint16_t i = 1; i < count; ++i) {
    const float value = values[i];
    int j = i - 1;
    while (j >= 0 && values[j] > value) {
      values[j + 1] = values[j];
      --j;
    }
    values[j + 1] = value;
  }
  if (count % 2) return values[count / 2];
  return (values[count / 2 - 1] + values[count / 2]) / 2.0f;
}

float roundMedian(const float *values, uint8_t &validCount) {
  float valid[ROUNDS];
  validCount = 0;
  for (uint8_t i = 0; i < ROUNDS; ++i)
    if (isfinite(values[i])) valid[validCount++] = values[i];
  return validCount >= MIN_VALID ? median(valid, validCount) : NAN;
}

void changeStage(Stage next) {
  stage = next;
  stageMs = millis();
}

const char *stageName() {
  switch (stage) {
    case WAIT_CYCLE: return "Waiting";
    case SYNC_CAMERA: return "Camera sync";
    case LEVEL_SETTLE: case LEVEL_SAMPLE: return "Level";
    case TURB_SETTLE: case TURB_SAMPLE: return "Turbidity";
    case TEMP_READ: return "Temperature";
    case CAMERA_WAIT: return "Camera";
    case TX_WAIT: return "LoRa";
  }
  return "?";
}

void drawScreen() {
  display.clear();
  display.setTextAlignment(TEXT_ALIGN_LEFT);
  display.setFont(ArialMT_Plain_10);
  char text[48];
  snprintf(text, sizeof(text), "%s R%d/5", stageName(), roundIndex + 1);
  display.drawString(0, 0, text);
  if (isfinite(resultLevelMV)) snprintf(text, sizeof(text), "Level: %.0f mV", resultLevelMV);
  else snprintf(text, sizeof(text), "Level: --");
  display.drawString(0, 12, text);
  if (isfinite(resultTurbMV)) snprintf(text, sizeof(text), "Turb: %.0f mV", resultTurbMV);
  else snprintf(text, sizeof(text), "Turb: --");
  display.drawString(0, 24, text);
  if (isfinite(resultTemp)) snprintf(text, sizeof(text), "Temp: %.2f C", resultTemp);
  else snprintf(text, sizeof(text), "Temp: --");
  display.drawString(0, 36, text);
  if ((millis() / 3000) % 2 == 0) {
    if (isfinite(resultAlgae)) snprintf(text, sizeof(text), "Algae: %.1f%%", resultAlgae);
    else snprintf(text, sizeof(text), "Algae: --");
  } else {
    snprintf(text, sizeof(text), "B%lu %s #%lu",
      (unsigned long)(hasBatch ? batchId : 0), txStatus, (unsigned long)sentCount);
  }
  display.drawString(0, 48, text);
  display.display();
}

void OnTxDone() {
  Radio.Sleep();
  transmitting = false;
  sentCount++;
  txStatus = "Sent";
  Serial.println("LoRa TX complete (no receiver acknowledgement)");
}
void OnTxTimeout() {
  Radio.Sleep();
  transmitting = false;
  txStatus = "Timeout";
  Serial.println("LoRa TX timeout");
}

void initLoRa() {
  RadioEvents.TxDone = OnTxDone;
  RadioEvents.TxTimeout = OnTxTimeout;
  Radio.Init(&RadioEvents);
  Radio.SetChannel(RF_FREQUENCY);
  Radio.SetTxConfig(MODEM_LORA, TX_OUTPUT_POWER, 0,
    LORA_BANDWIDTH, LORA_SPREADING_FACTOR, LORA_CODINGRATE,
    LORA_PREAMBLE_LENGTH, false, true, 0, 0, false, TX_TIMEOUT_VALUE);
  Radio.Sleep();
}

void formatValue(char *out, size_t size, float value, int decimals) {
  if (isfinite(value)) snprintf(out, size, "%.*f", decimals, value);
  else snprintf(out, size, "NA");
}

// Called only after round 5 completes and the camera reports flash OFF.
void finishBatch() {
  resultLevelMV = roundMedian(levelRounds, nLevel);
  resultTurbMV = roundMedian(turbRounds, nTurb);
  resultTemp = roundMedian(tempRounds, nTemp);
  resultAlgae = roundMedian(algaeRounds, nCamera);
  uint8_t ignored;
  resultConf = roundMedian(confRounds, ignored);
  resultQuality = roundMedian(qualityRounds, ignored);
  hasBatch = true;

  char level[16], turb[16], temp[16], algae[16], conf[16], quality[16], age[16];
  formatValue(level, sizeof(level), resultLevelMV, 1);
  formatValue(turb, sizeof(turb), resultTurbMV, 1);
  formatValue(temp, sizeof(temp), resultTemp, 2);
  formatValue(algae, sizeof(algae), resultAlgae, 2);
  formatValue(conf, sizeof(conf), resultConf, 2);
  formatValue(quality, sizeof(quality), resultQuality, 2);
  if (nCamera)
    snprintf(age, sizeof(age), "%lu", (unsigned long)((millis() - lastCameraMs) / 1000));
  else snprintf(age, sizeof(age), "NA");

  // Fresh means a valid aggregate from THIS completed batch.
  // CAM_AGE is the age of its latest valid camera observation.
  // CONF remains a heuristic, not a probability.
  // Raw values only: LVL_MV / TURB_MV are ADC-pin millivolts, TEMP is the
  // DS18B20's own reading in C. N_* are valid rounds out of 5 per sensor.
  // Worst case is ~170 bytes, inside the 255-byte LoRa limit.
  int length = snprintf(txPacket, sizeof(txPacket),
    "TEMP=%s,LVL_MV=%s,TURB_MV=%s,ALGAE=%s,CONF=%s,QUALITY=%s,"
    "CAM_FRESH=%d,CAM_ERR=%d,CAM_AGE=%s,"
    "N_LVL=%u,N_TURB=%u,N_TEMP=%u,N_CAM=%u,BATCH=%lu",
    temp, level, turb, algae, conf, quality,
    isfinite(resultAlgae) ? 1 : 0, cameraHadError ? 1 : 0, age,
    (unsigned)nLevel, (unsigned)nTurb, (unsigned)nTemp, (unsigned)nCamera,
    (unsigned long)batchId);

  Serial.printf("\nBATCH %lu: median of 5 rounds\n", (unsigned long)batchId);
  Serial.printf("Valid: level=%u turb=%u temp=%u camera=%u\n",
    (unsigned)nLevel, (unsigned)nTurb, (unsigned)nTemp, (unsigned)nCamera);

  if (length <= 0 || length >= (int)sizeof(txPacket) || length > 255) {
    txStatus = "Too long";
    Serial.println("Packet too long; not sent");
    changeStage(WAIT_CYCLE);
    drawScreen();
    return;
  }
  Serial.printf("LoRa sending: %s\n\n", txPacket);
  transmitting = true;
  txStatus = "Sending";
  changeStage(TX_WAIT);
  drawScreen();
  Radio.Send((uint8_t *)txPacket, (uint8_t)length);
}

void nextRound() {
  if (roundIndex + 1 >= ROUNDS) {
    finishBatch();
    return;
  }
  ++roundIndex;
  Serial.printf("\nROUND %u/5\n", (unsigned)(roundIndex + 1));
  changeStage(LEVEL_SETTLE);
  drawScreen(); // No OLED traffic during actual ADC collection.
}

void syncCamera(bool recovery) {
  recovering = recovery;
  activeId = ++requestId;
  changeStage(SYNC_CAMERA);
  Link.printf("PING:%lu\n", (unsigned long)activeId);
}

void startBatch() {
  firstCycle = false;
  cycleMs = millis();
  ++batchId;
  roundIndex = 0;
  cameraHadError = false;
  for (uint8_t i = 0; i < ROUNDS; ++i) {
    levelRounds[i] = turbRounds[i] = tempRounds[i] = NAN;
    algaeRounds[i] = confRounds[i] = qualityRounds[i] = NAN;
  }
  Radio.Sleep();
  Serial.printf("\nBATCH %lu: waiting for camera idle\n", (unsigned long)batchId);
  syncCamera(false);
}

bool percentage(float x) { return isfinite(x) && x >= 0 && x <= 100; }

// Responses carry a request ID, so late/duplicate replies cannot enter
// a different round. Any result/error is sent only AFTER flash is OFF.
void processCameraLine(const char *line) {
  unsigned long id = 0;
  int used = 0;
  if (stage == SYNC_CAMERA &&
      sscanf(line, "IDLE:%lu%n", &id, &used) == 1 &&
      used > 0 && line[used] == '\0' && id == activeId) {
    if (recovering) {
      nextRound(); // Timed-out camera round remains invalid.
    } else {
      Serial.println("Camera idle confirmed; ROUND 1/5");
      changeStage(LEVEL_SETTLE);
      drawScreen();
    }
    return;
  }
  if (stage != CAMERA_WAIT) return;

  float g = NAN, c = NAN, q = NAN;
  used = 0;
  if (sscanf(line, "R:%lu,G:%f,C:%f,Q:%f%n", &id, &g, &c, &q, &used) == 4 &&
      used > 0 && line[used] == '\0' && id == activeId &&
      percentage(g) && percentage(c) && percentage(q)) {
    Serial.printf("Round %u camera: G=%.2f C*=%.2f Q=%.2f (flash OFF)\n",
      (unsigned)(roundIndex + 1), g, c, q);
    if (q > 0) {
      algaeRounds[roundIndex] = g;
      confRounds[roundIndex] = c;
      qualityRounds[roundIndex] = q;
      lastCameraMs = millis();
    } else {
      cameraHadError = true;
      Serial.println("Camera Q=0: unmeasurable, not clean water");
    }
    nextRound();
    return;
  }
  char error[24];
  used = 0;
  if (sscanf(line, "E:%lu,%23[A-Z_]%n", &id, error, &used) == 2 &&
      used > 0 && line[used] == '\0' && id == activeId) {
    cameraHadError = true;
    Serial.printf("Camera error: %s (flash OFF)\n", error);
    nextRound();
  }
}

void receiveCamera() {
  static char line[100];
  static uint8_t pos = 0;
  static bool discard = false;
  while (Link.available()) {
    int ch = Link.read();
    if (ch < 0) break;
    if (ch == '\n' || ch == '\r') {
      if (!discard && pos) {
        line[pos] = '\0';
        processCameraLine(line);
      }
      pos = 0;
      discard = false;
    } else if (!discard) {
      if (ch < 32 || ch > 126 || pos >= sizeof(line) - 1) {
        discard = true;
        pos = 0;
      } else line[pos++] = (char)ch;
    }
  }
}

void startADC(int pin, Stage next) {
  analogReadMilliVolts(pin); // Discard first read after channel switch.
  adcCount = 0;
  sampleMs = millis();
  changeStage(next);
}

bool collectADC(int pin, float &mv) {
  if (millis() - sampleMs < ADC_INTERVAL_MS) return false;
  sampleMs = millis();
  adcSamples[adcCount++] = (uint16_t)analogReadMilliVolts(pin);
  if (adcCount < ADC_SAMPLES) return false;
  float values[ADC_SAMPLES];
  for (uint16_t i = 0; i < ADC_SAMPLES; ++i) values[i] = adcSamples[i];
  mv = median(values, ADC_SAMPLES);
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(1000);
  Mcu.begin(HELTEC_BOARD, SLOW_CLK_TPYE);
  pinMode(Vext, OUTPUT);
  digitalWrite(Vext, LOW);
  delay(100);
  display.init();
  Link.begin(LINK_BAUD, SERIAL_8N1, LINK_RX, LINK_TX);
  requestId = esp_random();
  pinMode(LEVEL_PIN, INPUT);
  pinMode(TURBIDITY_PIN, INPUT);
  analogReadResolution(12);
  // Retains the supplied converter's low-voltage ADC configuration.
  // Revisit attenuation AND calibration if converter output range changes.
  analogSetPinAttenuation(LEVEL_PIN, ADC_0db);
  analogSetPinAttenuation(TURBIDITY_PIN, ADC_11db);
  sensors.begin();
  // Same blocking conversion setup as the working GPIO19 test.
  sensors.setWaitForConversion(true);
  sensors.setResolution(12);
  initLoRa();
  Serial.println("HERDRA: 5 sequential rounds, then medians and one LoRa packet");
  Serial.println("Level=GPIO3 Turbidity=GPIO4 Temperature=GPIO19 UART=6/7");
  Serial.printf("Temperature sensors found: %d\n", sensors.getDeviceCount());
  Serial.println("Sending raw mV; calibration lives in the TroughWatch app.");
  drawScreen();
}

void loop() {
  Radio.IrqProcess();
  receiveCamera();
  const uint32_t now = millis();
  float mv = NAN;
  switch (stage) {
    case WAIT_CYCLE:
      if (firstCycle || now - cycleMs >= CYCLE_INTERVAL_MS) startBatch();
      break;
    case SYNC_CAMERA:
      // Retry synchronization; do not sample while camera state is unknown.
      if (now - stageMs >= SYNC_RETRY_MS) {
        Serial.println("Waiting for camera idle: check both firmwares and UART wiring");
        syncCamera(recovering);
      }
      break;
    case LEVEL_SETTLE:
      if (now - stageMs >= SETTLE_MS) startADC(LEVEL_PIN, LEVEL_SAMPLE);
      break;
    case LEVEL_SAMPLE:
      if (collectADC(LEVEL_PIN, mv)) {
        if (isfinite(mv)) levelRounds[roundIndex] = mv;
        Serial.printf("Round %u LEVEL median: %.1f mV\n",
          (unsigned)(roundIndex + 1), mv);
        changeStage(TURB_SETTLE);
        drawScreen();
      }
      break;
    case TURB_SETTLE:
      if (now - stageMs >= SETTLE_MS) startADC(TURBIDITY_PIN, TURB_SAMPLE);
      break;
    case TURB_SAMPLE:
      if (collectADC(TURBIDITY_PIN, mv)) {
        if (isfinite(mv)) turbRounds[roundIndex] = mv;
        Serial.printf("Round %u TURB median: %.1f mV at GPIO4\n",
          (unsigned)(roundIndex + 1), mv);
        changeStage(TEMP_READ);
        drawScreen();
      }
      break;
    case TEMP_READ: {
        // Request and wait, then read immediately, as in the working test.
        sensors.requestTemperatures();
        float t = sensors.getTempCByIndex(0);
        if (isfinite(t) && t != DEVICE_DISCONNECTED_C && t >= -55 && t <= 125)
          tempRounds[roundIndex] = t;
        else
          Serial.println("Temperature unavailable. Check GPIO19, power, GND and pull-up resistor.");
        Serial.printf("Round %u TEMP: %.2f C (nan = unavailable)\n",
          (unsigned)(roundIndex + 1), tempRounds[roundIndex]);
        activeId = ++requestId;
        changeStage(CAMERA_WAIT);
        Link.printf("CAPTURE:%lu\n", (unsigned long)activeId);
        drawScreen();
      }
      break;
    case CAMERA_WAIT:
      if (now - stageMs >= CAMERA_TIMEOUT_MS) {
        cameraHadError = true;
        Serial.println("Camera timeout; round invalid. Waiting for flash-off confirmation.");
        syncCamera(true);
      }
      break;
    case TX_WAIT:
      if (!transmitting) changeStage(WAIT_CYCLE);
      else if (now - stageMs > TX_TIMEOUT_VALUE + 2000) {
        // Fallback if no radio callback arrives.
        OnTxTimeout();
        changeStage(WAIT_CYCLE);
      }
      break;
  }
  // Freeze OLED transfers throughout the sensitive analog phases.
  if ((stage == WAIT_CYCLE || stage == SYNC_CAMERA || stage == TEMP_READ ||
       stage == CAMERA_WAIT || stage == TX_WAIT) &&
      millis() - lastDisplayMs >= 500) {
    lastDisplayMs = millis();
    drawScreen();
  }
}
