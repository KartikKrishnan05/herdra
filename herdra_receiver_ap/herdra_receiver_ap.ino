#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <DNSServer.h>
#include <ESPmDNS.h>

#include "LoRaWan_APP.h"
#include "HT_SSD1306Wire.h"

// =====================================================
// OLED
// =====================================================

SSD1306Wire oled(
  0x3c,
  500000,
  SDA_OLED,
  SCL_OLED,
  GEOMETRY_128_64,
  RST_OLED
);

// =====================================================
// ACCESS POINT SETTINGS
// The Heltec creates this network, the iPhone joins it.
// Password must be at least 8 characters (or "" for open).
// =====================================================

const char* AP_SSID = "HERDRA-RX";
const char* AP_PASS = "herdra1234";

IPAddress AP_IP(192, 168, 4, 1);
IPAddress AP_MASK(255, 255, 255, 0);

WebServer  server(80);
DNSServer  dns;

// =====================================================
// LORA SETTINGS
// IMPORTANT: sender must use the SAME settings
// =====================================================

#define RF_FREQUENCY 868000000

#define LORA_BANDWIDTH 0
#define LORA_SPREADING_FACTOR 7
#define LORA_CODINGRATE 1
#define LORA_PREAMBLE_LENGTH 8

#define LORA_SYMBOL_TIMEOUT 0
#define LORA_FIX_LENGTH_PAYLOAD_ON false
#define LORA_IQ_INVERSION_ON false

#define BUFFER_SIZE 256

char rxpacket[BUFFER_SIZE];

static RadioEvents_t RadioEvents;

// =====================================================
// PACKET RING BUFFER
// Holds the last MAX_PACKETS packets in RAM.
// =====================================================

#define MAX_PACKETS 50

struct Packet
{
  String   msg;
  int16_t  rssi;
  int8_t   snr;
  uint32_t ms;      // millis() at reception
  uint32_t id;      // running packet number
};

Packet   packets[MAX_PACKETS];
int      head        = 0;   // next write slot
uint32_t totalCount  = 0;   // total packets ever received

String   lastMessage = "Waiting...";
int16_t  lastRSSI    = 0;
int8_t   lastSNR     = 0;

uint32_t lastOledUpdate = 0;

// =====================================================
// HELPERS
// =====================================================

String jsonEscape(const String& in)
{
  String out;
  out.reserve(in.length() + 8);

  for (size_t i = 0; i < in.length(); i++)
  {
    char c = in[i];

    switch (c)
    {
      case '"':  out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n";  break;
      case '\r': out += "\\r";  break;
      case '\t': out += "\\t";  break;
      default:
        if ((uint8_t)c < 0x20)
        {
          char b[7];
          sprintf(b, "\\u%04x", c);
          out += b;
        }
        else
        {
          out += c;
        }
    }
  }

  return out;
}

String csvEscape(const String& in)
{
  String out = in;
  out.replace("\"", "\"\"");
  return "\"" + out + "\"";
}

void storePacket(const String& msg, int16_t rssi, int8_t snr)
{
  totalCount++;

  packets[head].msg  = msg;
  packets[head].rssi = rssi;
  packets[head].snr  = snr;
  packets[head].ms   = millis();
  packets[head].id   = totalCount;

  head = (head + 1) % MAX_PACKETS;
}

// =====================================================
// OLED
// =====================================================

void showStatus()
{
  oled.clear();

  oled.setTextAlignment(TEXT_ALIGN_LEFT);
  oled.setFont(ArialMT_Plain_10);

  oled.drawString(0, 0,
    "AP: " + String(AP_SSID));

  oled.drawString(0, 12,
    WiFi.softAPIP().toString() +
    "  [" + String(WiFi.softAPgetStationNum()) + "]");

  String msg = lastMessage;

  if (msg.length() <= 21)
  {
    oled.drawString(0, 26, msg);
  }
  else
  {
    oled.drawString(0, 26, msg.substring(0, 21));

    if (msg.length() > 42)
    {
      oled.drawString(0, 38, msg.substring(21, 42));
    }
    else
    {
      oled.drawString(0, 38, msg.substring(21));
    }
  }

  oled.drawString(0, 52,
    "#" + String(totalCount) +
    "  " + String(lastRSSI) + "dBm" +
    "  " + String(lastSNR) + "dB");

  oled.display();
}

// =====================================================
// WEB PAGE
// =====================================================

const char PAGE_INDEX[] PROGMEM = R"HTMLPAGE(
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>HERDRA Receiver</title>
<style>
  :root {
    --bg:#0d1117; --card:#161b22; --line:#30363d;
    --fg:#e6edf3; --dim:#8b949e; --ok:#3fb950; --warn:#d29922;
  }
  * { box-sizing:border-box; }
  body {
    margin:0; padding:16px calc(16px + env(safe-area-inset-left)) 40px;
    background:var(--bg); color:var(--fg);
    font:15px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;
  }
  header { display:flex; align-items:baseline; gap:10px; margin-bottom:4px; }
  h1 { font-size:19px; margin:0; letter-spacing:.3px; }
  .live { font-size:12px; color:var(--ok); }
  .live.paused { color:var(--warn); }
  .meta { color:var(--dim); font-size:13px; margin-bottom:14px; }
  .bar { display:flex; gap:8px; margin-bottom:14px; flex-wrap:wrap; }
  button, a.btn {
    appearance:none; border:1px solid var(--line); background:var(--card);
    color:var(--fg); border-radius:9px; padding:8px 14px; font-size:14px;
    text-decoration:none; -webkit-tap-highlight-color:transparent;
  }
  button:active, a.btn:active { background:#21262d; }
  .pkt {
    background:var(--card); border:1px solid var(--line);
    border-radius:11px; padding:11px 13px; margin-bottom:9px;
  }
  .pkt .top {
    display:flex; justify-content:space-between;
    font-size:12px; color:var(--dim); margin-bottom:6px;
  }
  .pkt .msg {
    font-family:ui-monospace,"SF Mono",Menlo,monospace;
    font-size:14px; word-break:break-word; white-space:pre-wrap;
  }
  .empty { color:var(--dim); text-align:center; padding:40px 0; }
</style>
</head>
<body>

<header>
  <h1>HERDRA Receiver</h1>
  <span class="live" id="live">live</span>
</header>

<div class="meta" id="meta">connecting...</div>

<div class="bar">
  <button id="toggle">Pause</button>
  <button id="clear">Clear</button>
  <a class="btn" href="/csv" download>Download CSV</a>
</div>

<div id="list"><div class="empty">No packets yet</div></div>

<script>
var paused = false;

function ago(ms) {
  var s = Math.round(ms / 1000);
  if (s < 60) return s + "s ago";
  var m = Math.floor(s / 60);
  if (m < 60) return m + "m " + (s % 60) + "s ago";
  return Math.floor(m / 60) + "h " + (m % 60) + "m ago";
}

function esc(t) {
  return t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function render(d) {
  document.getElementById("meta").textContent =
    d.total + " packets - uptime " + ago(d.uptime).replace(" ago", "") +
    " - " + d.clients + " client(s)";

  var list = document.getElementById("list");

  if (!d.packets.length) {
    list.innerHTML = '<div class="empty">No packets yet</div>';
    return;
  }

  var html = "";
  for (var i = d.packets.length - 1; i >= 0; i--) {
    var p = d.packets[i];
    html +=
      '<div class="pkt"><div class="top"><span>#' + p.id + " - " + ago(p.age) +
      "</span><span>RSSI " + p.rssi + " dBm / SNR " + p.snr +
      ' dB</span></div><div class="msg">' + esc(p.msg) + "</div></div>";
  }
  list.innerHTML = html;
}

function poll() {
  if (paused) return;
  fetch("/data", { cache: "no-store" })
    .then(function (r) { return r.json(); })
    .then(render)
    .catch(function () {
      document.getElementById("meta").textContent = "connection lost - retrying";
    });
}

document.getElementById("toggle").onclick = function () {
  paused = !paused;
  this.textContent = paused ? "Resume" : "Pause";
  var l = document.getElementById("live");
  l.textContent = paused ? "paused" : "live";
  l.className = "live" + (paused ? " paused" : "");
  if (!paused) poll();
};

document.getElementById("clear").onclick = function () {
  fetch("/clear").then(poll);
};

poll();
setInterval(poll, 1000);
</script>

</body>
</html>
)HTMLPAGE";

// =====================================================
// WEB HANDLERS
// =====================================================

void handleRoot()
{
  server.sendHeader("Cache-Control", "no-store");
  server.send_P(200, "text/html", PAGE_INDEX);
}

void handleData()
{
  uint32_t now = millis();

  String json = "{";
  json += "\"total\":" + String(totalCount) + ",";
  json += "\"uptime\":" + String(now) + ",";
  json += "\"clients\":" + String(WiFi.softAPgetStationNum()) + ",";
  json += "\"packets\":[";

  int stored = (totalCount < MAX_PACKETS)
                 ? (int)totalCount
                 : MAX_PACKETS;

  bool first = true;

  for (int i = 0; i < stored; i++)
  {
    // oldest -> newest
    int idx = (head - stored + i + MAX_PACKETS * 2) % MAX_PACKETS;

    if (!first) json += ",";
    first = false;

    json += "{\"id\":"   + String(packets[idx].id);
    json += ",\"rssi\":" + String(packets[idx].rssi);
    json += ",\"snr\":"  + String(packets[idx].snr);
    json += ",\"age\":"  + String(now - packets[idx].ms);
    json += ",\"msg\":\"" + jsonEscape(packets[idx].msg) + "\"}";
  }

  json += "]}";

  server.sendHeader("Cache-Control", "no-store");
  server.send(200, "application/json", json);
}

void handleCsv()
{
  String csv = "id,age_ms,rssi_dbm,snr_db,message\n";

  uint32_t now = millis();

  int stored = (totalCount < MAX_PACKETS)
                 ? (int)totalCount
                 : MAX_PACKETS;

  for (int i = 0; i < stored; i++)
  {
    int idx = (head - stored + i + MAX_PACKETS * 2) % MAX_PACKETS;

    csv += String(packets[idx].id) + ",";
    csv += String(now - packets[idx].ms) + ",";
    csv += String(packets[idx].rssi) + ",";
    csv += String(packets[idx].snr) + ",";
    csv += csvEscape(packets[idx].msg) + "\n";
  }

  server.sendHeader(
    "Content-Disposition",
    "attachment; filename=\"herdra_packets.csv\""
  );

  server.send(200, "text/csv", csv);
}

void handleClear()
{
  head       = 0;
  totalCount = 0;

  for (int i = 0; i < MAX_PACKETS; i++)
  {
    packets[i].msg = "";
  }

  lastMessage = "Waiting...";
  showStatus();

  server.send(200, "text/plain", "cleared");
}

void handleNotFound()
{
  String uri  = server.uri();
  String host = server.hostHeader();

  // Answer Apple's captive-portal probe with "Success" so iOS
  // keeps the WiFi connection instead of dropping back to cellular.
  if (uri.indexOf("hotspot-detect") >= 0 ||
      host.indexOf("captive.apple.com") >= 0 ||
      host.indexOf("apple.com") >= 0)
  {
    server.send(200, "text/html",
      "<HTML><HEAD><TITLE>Success</TITLE></HEAD>"
      "<BODY>Success</BODY></HTML>");
    return;
  }

  server.sendHeader("Location", "http://192.168.4.1/", true);
  server.send(302, "text/plain", "");
}

// =====================================================
// LORA RECEIVE CALLBACK
// =====================================================

void OnRxDone(
  uint8_t* payload,
  uint16_t size,
  int16_t rssi,
  int8_t snr
)
{
  if (size >= BUFFER_SIZE)
  {
    size = BUFFER_SIZE - 1;
  }

  memcpy(rxpacket, payload, size);
  rxpacket[size] = '\0';

  lastRSSI = rssi;
  lastSNR  = snr;

  String received = String(rxpacket);
  lastMessage = received;

  storePacket(received, rssi, snr);

  Serial.println();
  Serial.println("==========================");
  Serial.println("LORA PACKET RECEIVED");
  Serial.println("==========================");
  Serial.print("Message: "); Serial.println(received);
  Serial.print("RSSI: ");    Serial.println(lastRSSI);
  Serial.print("SNR: ");     Serial.println(lastSNR);

  showStatus();

  // Continue receiving
  Radio.Rx(0);
}

// =====================================================
// ACCESS POINT
// =====================================================

void startAccessPoint()
{
  WiFi.mode(WIFI_AP);
  WiFi.softAPConfig(AP_IP, AP_IP, AP_MASK);

  // ssid, password, channel, hidden, max connections
  WiFi.softAP(AP_SSID, AP_PASS, 1, 0, 4);

  delay(300);

  Serial.println();
  Serial.print("Access point: ");
  Serial.println(AP_SSID);
  Serial.print("Password:     ");
  Serial.println(AP_PASS);
  Serial.print("Open in Safari: http://");
  Serial.println(WiFi.softAPIP());

  // Wildcard DNS -> any hostname resolves to the board
  dns.start(53, "*", AP_IP);

  // Also reachable as http://herdra.local
  MDNS.begin("herdra");
  MDNS.addService("http", "tcp", 80);

  server.on("/",      handleRoot);
  server.on("/data",  handleData);
  server.on("/csv",   handleCsv);
  server.on("/clear", handleClear);
  server.onNotFound(handleNotFound);

  server.begin();
}

// =====================================================
// SETUP
// =====================================================

void setup()
{
  Serial.begin(115200);
  delay(1000);

  Mcu.begin(HELTEC_BOARD, SLOW_CLK_TPYE);

  // OLED power
  pinMode(Vext, OUTPUT);
  digitalWrite(Vext, LOW);
  delay(200);

  oled.init();
  oled.clear();
  oled.setTextAlignment(TEXT_ALIGN_LEFT);
  oled.setFont(ArialMT_Plain_10);
  oled.drawString(0, 0,  "HERDRA Receiver");
  oled.drawString(0, 16, "Starting AP...");
  oled.display();
  delay(800);

  startAccessPoint();

  // --------------------------------------
  // LORA
  // --------------------------------------

  RadioEvents.RxDone = OnRxDone;

  Radio.Init(&RadioEvents);

  Radio.SetChannel(RF_FREQUENCY);

  Radio.SetRxConfig(
    MODEM_LORA,
    LORA_BANDWIDTH,
    LORA_SPREADING_FACTOR,
    LORA_CODINGRATE,
    0,
    LORA_PREAMBLE_LENGTH,
    LORA_SYMBOL_TIMEOUT,
    LORA_FIX_LENGTH_PAYLOAD_ON,
    0,
    true,
    0,
    0,
    LORA_IQ_INVERSION_ON,
    true
  );

  lastMessage = "Waiting...";
  showStatus();

  Serial.println("LoRa receiver ready");
  Serial.println("Waiting for packets...");

  Radio.Rx(0);
}

// =====================================================
// LOOP
// =====================================================

void loop()
{
  Radio.IrqProcess();

  dns.processNextRequest();
  server.handleClient();

  // Refresh the OLED twice a second (client count changes)
  if (millis() - lastOledUpdate > 500)
  {
    lastOledUpdate = millis();
    showStatus();
  }
}
