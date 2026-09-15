#include <Arduino.h>
#include "esp_camera.h"

// Prototype: estimates algae-like COLOR coverage, not algae identity/toxicity.
// Camera pins and RGB565 byte order retained from your working sketch.
#define PWDN_GPIO_NUM  -1
#define RESET_GPIO_NUM -1
#define XCLK_GPIO_NUM  15
#define SIOD_GPIO_NUM   4
#define SIOC_GPIO_NUM   5
#define Y9_GPIO_NUM    16
#define Y8_GPIO_NUM    17
#define Y7_GPIO_NUM    18
#define Y6_GPIO_NUM    12
#define Y5_GPIO_NUM    10
#define Y4_GPIO_NUM     8
#define Y3_GPIO_NUM     9
#define Y2_GPIO_NUM    11
#define VSYNC_GPIO_NUM  6
#define HREF_GPIO_NUM   7
#define PCLK_GPIO_NUM  13

// Camera GPIO1 -> Heltec GPIO6; camera GPIO2 <- Heltec GPIO7.
// Connect both grounds.
#define LINK_TX 1
#define LINK_RX 2
#define LINK_BAUD 115200
HardwareSerial Link(1);

#define FLASH_PIN 14
#define FLASH_ON_LEVEL HIGH
#define FLASH_OFF_LEVEL LOW
#define FLASH_SETTLE_MS 300
#define FRAMES_PER_CYCLE 3
#define BETWEEN_FRAMES_MS 150
#define READING_DELAY_MS 2000
#define SWAP_BYTES true

// Starting thresholds, NOT calibrated measurements.
// Hue is in DEGREES (0..360), saturation is 0..1, value is 0..255.
const float ALGAE_HUE_MIN = 45.0f;
const float ALGAE_HUE_MAX = 165.0f;
const float ALGAE_SAT_MIN = 0.22f;
// Additional branch for muted green seen in your actual camera captures.
// Require BOTH a relative tint and an absolute green excess to avoid
// accepting neutral RGB565 gray just from unequal channel quantization.
const float MUTED_SAT_MIN = 0.04f;
const float MUTED_HUE_MIN = 65.0f;
const float MUTED_HUE_MAX = 165.0f;
const int MUTED_MIN_VALUE = 50;
const int MUTED_CHANNEL_MARGIN = 3;
const int MUTED_GREEN_EXCESS = 10; // 2*G - R - B, in 8-bit RGB units

const int MIN_VALUE = 25;
const int GLARE_VALUE = 245;
const float GLARE_SAT_MAX = 0.12f;

// Ignore 10% of the image on each edge. Position the bottom/printed
// picture inside this central rectangle. This is NOT automatic trough detection.
const int ROI_MARGIN_PERCENT = 10;
// Skip dark / near-white clipped samples. Low usable area now only warns;
// it does NOT stop UART percentages. Percentage is over USABLE ROI samples.
// If no samples are usable, send G:0,C:0,Q:0 (unmeasurable, NOT clean).
const float MIN_USABLE_PERCENT = 60.0f;

// Analyze a uniform 160x120 sample grid over the ROI.
#define SAMPLE_W 160
#define SAMPLE_H 120
// 0 = other color, 1 = algae-like color, 2 = unusable.
static uint8_t mask[SAMPLE_H][SAMPLE_W];
static uint8_t patches[SAMPLE_H][SAMPLE_W];
static uint16_t patchQueue[SAMPLE_W * SAMPLE_H];
// Heuristic only: a connected patch occupying 2% of the entire ROI gives
// full spatial evidence. Tunable demo threshold, NOT learned/calibrated.
const float STRONG_PATCH_PERCENT = 2.0f;
static const char *frameError = "FRAME";
static_assert(ROI_MARGIN_PERCENT >= 0 && ROI_MARGIN_PERCENT < 50,
              "ROI margin must be 0..49");

void setFlash(bool on) {
  digitalWrite(FLASH_PIN, on ? FLASH_ON_LEVEL : FLASH_OFF_LEVEL);
}

// Classify one decoded RGB pixel.
uint8_t classifyPixel(int r, int g, int b) {
  int hi = r;
  if (g > hi) hi = g;
  if (b > hi) hi = b;
  int lo = r;
  if (g < lo) lo = g;
  if (b < lo) lo = b;
  const int delta = hi - lo;
  const float sat = hi > 0 ? (float)delta / hi : 0.0f;
  if (hi < MIN_VALUE || (hi >= GLARE_VALUE && sat < GLARE_SAT_MAX))
    return 2;
  if (delta == 0 || sat < MUTED_SAT_MIN) return 0;

  float hue;
  if (hi == r) hue = 60.0f * (g - b) / delta;
  else if (hi == g) hue = 120.0f + 60.0f * (b - r) / delta;
  else hue = 240.0f + 60.0f * (r - g) / delta;
  if (hue < 0.0f) hue += 360.0f;
  const bool strongColor = sat >= ALGAE_SAT_MIN &&
    hue >= ALGAE_HUE_MIN && hue <= ALGAE_HUE_MAX;
  const bool mutedColor = hi >= MUTED_MIN_VALUE &&
    hue >= MUTED_HUE_MIN && hue <= MUTED_HUE_MAX &&
    g - r >= MUTED_CHANNEL_MARGIN && g - b >= MUTED_CHANNEL_MARGIN &&
    2 * g - r - b >= MUTED_GREEN_EXCESS;
  return (strongColor || mutedColor) ? 1 : 0;
}

// Largest four-connected patch in the filtered sample grid.
// Flood fill marks on enqueue, so the queue cannot exceed the sample count.
uint32_t largestPatch() {
  uint32_t largest = 0;
  for (int y = 0; y < SAMPLE_H; y++) {
    for (int x = 0; x < SAMPLE_W; x++) {
      if (!patches[y][x]) continue;
      uint32_t head = 0, tail = 0;
      patches[y][x] = 0;
      patchQueue[tail++] = y * SAMPLE_W + x;
      while (head < tail) {
        const int cell = patchQueue[head++];
        const int cy = cell / SAMPLE_W, cx = cell % SAMPLE_W;
        const int dx[4] = {-1, 1, 0, 0};
        const int dy[4] = {0, 0, -1, 1};
        for (int k = 0; k < 4; k++) {
          const int nx = cx + dx[k], ny = cy + dy[k];
          if (nx < 0 || nx >= SAMPLE_W || ny < 0 || ny >= SAMPLE_H)
            continue;
          if (patches[ny][nx]) {
            patches[ny][nx] = 0;
            patchQueue[tail++] = ny * SAMPLE_W + nx;
          }
        }
      }
      if (tail > largest) largest = tail;
    }
  }
  return largest;
}

bool analyzeFrame(camera_fb_t *fb, float &pct, float &usablePct, float &evidence) {
  frameError = "FRAME";
  const uint32_t w = fb->width;
  const uint32_t h = fb->height;
  if (fb->format != PIXFORMAT_RGB565 || !fb->buf || w == 0 || h == 0 ||
      fb->len < (size_t)w * h * 2) return false;
  const uint32_t x0 = w * ROI_MARGIN_PERCENT / 100;
  const uint32_t y0 = h * ROI_MARGIN_PERCENT / 100;
  const uint32_t rw = w - 2 * x0;
  const uint32_t rh = h - 2 * y0;
  if (rw < SAMPLE_W || rh < SAMPLE_H) return false;

  uint32_t darkCount = 0, glareCount = 0;
  for (int sy = 0; sy < SAMPLE_H; sy++) {
    const uint32_t y = y0 + (2 * sy + 1) * rh / (2 * SAMPLE_H);
    for (int sx = 0; sx < SAMPLE_W; sx++) {
      const uint32_t x = x0 + (2 * sx + 1) * rw / (2 * SAMPLE_W);
      const size_t i = ((size_t)y * w + x) * 2;
      const uint16_t p = SWAP_BYTES
        ? ((uint16_t)fb->buf[i] << 8) | fb->buf[i + 1]
        : ((uint16_t)fb->buf[i + 1] << 8) | fb->buf[i];
      // Expand RGB565 to the full 0..255 range.
      const int r = ((p >> 11) & 31) * 255 / 31;
      const int g = ((p >> 5) & 63) * 255 / 63;
      const int b = (p & 31) * 255 / 31;
      mask[sy][sx] = classifyPixel(r, g, b);
      if (mask[sy][sx] == 2) {
        if (r < MIN_VALUE && g < MIN_VALUE && b < MIN_VALUE) darkCount++;
        else glareCount++;
      }
    }
  }

  uint32_t usable = 0;
  uint32_t algae = 0;
  for (int y = 0; y < SAMPLE_H; y++) {
    for (int x = 0; x < SAMPLE_W; x++) {
      patches[y][x] = 0;
      if (mask[y][x] == 2) continue;
      usable++;
      int votes = 0;
      int neighbors = 0;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          const int yy = y + dy;
          const int xx = x + dx;
          if (yy < 0 || yy >= SAMPLE_H || xx < 0 || xx >= SAMPLE_W)
            continue;
          if (mask[yy][xx] == 2) continue;
          neighbors++;
          votes += (mask[yy][xx] == 1);
        }
      }
      // Majority filter removes isolated dots / fills tiny valid gaps.
      // Ties or too little neighbor evidence retain the original class.
      const bool detected = (neighbors < 3 || votes * 2 == neighbors)
        ? mask[y][x] == 1 : votes * 2 > neighbors;
      if (detected) { algae++; patches[y][x] = 1; }
    }
  }
  usablePct = 100.0f * usable / (SAMPLE_W * SAMPLE_H);
  if (usable == 0) {
    frameError = darkCount >= glareCount ? "DARK" : "GLARE";
    // No visible evidence can be measured. The Q:0 flag is essential.
    pct = 0;
    evidence = 0;
    return true;
  }
  pct = 100.0f * algae / usable;
  const float patchPct = 100.0f * largestPatch() / (SAMPLE_W * SAMPLE_H);
  float strength = patchPct / STRONG_PATCH_PERCENT;
  if (strength > 1.0f) strength = 1.0f;
  // Quality discounts evidence when much of the ROI cannot be inspected.
  evidence = strength * usablePct;
  return true;
}

void setup() {
  pinMode(FLASH_PIN, OUTPUT);
  setFlash(false);
  Serial.begin(115200);
  Link.begin(LINK_BAUD, SERIAL_8N1, LINK_RX, LINK_TX);
  delay(1000);
  Serial.println("\nAlgae-like coverage detector: HSV + spatial filter");
  if (!psramFound()) {
    Serial.println("ERROR: PSRAM not found. Check OPI PSRAM setting.");
    while (true) delay(1000);
  }
  camera_config_t c = {};
  c.ledc_channel = LEDC_CHANNEL_0;
  c.ledc_timer = LEDC_TIMER_0;
  c.pin_d0 = Y2_GPIO_NUM;
  c.pin_d1 = Y3_GPIO_NUM;
  c.pin_d2 = Y4_GPIO_NUM;
  c.pin_d3 = Y5_GPIO_NUM;
  c.pin_d4 = Y6_GPIO_NUM;
  c.pin_d5 = Y7_GPIO_NUM;
  c.pin_d6 = Y8_GPIO_NUM;
  c.pin_d7 = Y9_GPIO_NUM;
  c.pin_xclk = XCLK_GPIO_NUM;
  c.pin_pclk = PCLK_GPIO_NUM;
  c.pin_vsync = VSYNC_GPIO_NUM;
  c.pin_href = HREF_GPIO_NUM;
  c.pin_sccb_sda = SIOD_GPIO_NUM;
  c.pin_sccb_scl = SIOC_GPIO_NUM;
  c.pin_pwdn = PWDN_GPIO_NUM;
  c.pin_reset = RESET_GPIO_NUM;
  c.xclk_freq_hz = 10000000;
  c.pixel_format = PIXFORMAT_RGB565;
  c.frame_size = FRAMESIZE_QVGA;
  c.fb_count = 1;
  c.fb_location = CAMERA_FB_IN_PSRAM;
  c.grab_mode = CAMERA_GRAB_LATEST;
  const esp_err_t err = esp_camera_init(&c);
  if (err != ESP_OK) {
    Serial.printf("Camera init FAILED: 0x%x\n", (unsigned int)err);
    while (true) delay(1000);
  }
  Serial.println("Camera OK. UART TX=1 RX=2; flash=14.");
  Serial.println("Every acquired RGB565 frame sends its own G,C,Q values; no averaging.");
}

void loop() {
  setFlash(true);
  delay(FLASH_SETTLE_MS);
  // Process ALL acquired images, including the first frames while exposure
  // adapts. No warmup frames are discarded. One packet per returned image.
  for (int n = 0; n < FRAMES_PER_CYCLE; n++) {
    camera_fb_t *fb = esp_camera_fb_get();
    if (!fb) {
      Serial.println("No image returned: CAPTURE");
      Link.println("E:CAPTURE");
    } else {
      float coverage = 0, quality = 0, confidence = 0;
      const bool decoded = analyzeFrame(fb, coverage, quality, confidence);
      esp_camera_fb_return(fb);
      if (decoded) {
        // Current frame only. Confidence is a spatial/color heuristic,
        // discounted by image quality; it is NOT a probability.
        Link.printf("G:%.2f,C:%.2f,Q:%.2f\n", coverage, confidence, quality);
        Serial.printf("TX G:%.2f,C:%.2f,Q:%.2f\n", coverage, confidence, quality);
        if (quality == 0)
          Serial.printf("%s: zeros mean UNMEASURABLE, not no algae.\n", frameError);
        else if (quality < MIN_USABLE_PERCENT)
          Serial.println("LOW quality: coverage uses the remaining usable pixels.");
      } else {
        Serial.println("Image cannot be decoded: FRAME");
        Link.println("E:FRAME");
      }
    }
    if (n + 1 < FRAMES_PER_CYCLE) delay(BETWEEN_FRAMES_MS);
  }
  setFlash(false);
  delay(READING_DELAY_MS);
}
