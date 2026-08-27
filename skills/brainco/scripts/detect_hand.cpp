// detect_hand.cpp — BrainCo Revo dexterous hand identification & health check.
//
// Scans serial ports for hands, reports the exact model (BASIC / TOUCH /
// TOUCH-PRESSURE), and EMPIRICALLY probes whether a tactile module answers —
// rather than trusting the hardware_type byte alone.
//
// Read-only: never sends a motion command.
//
// Build: see scripts/build.sh
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include "stark-sdk.h"

// StarkHardwareType -> human-readable model, and whether touch is expected.
struct Model { const char* name; bool touch; };
static Model model_of(uint8_t t) {
  switch (t) {
    case 0: return {"Revo1 (legacy Protobuf)",              false};
    case 1: return {"Revo1 BASIC",                          false};
    case 2: return {"Revo1 TOUCH (capacitive)",             true };
    case 3: return {"Revo1 ADVANCED",                       false};
    case 4: return {"Revo1 ADVANCED TOUCH (capacitive)",    true };
    case 5: return {"Revo2 BASIC",                          false};
    case 6: return {"Revo2 TOUCH (capacitive)",             true };
    case 7: return {"Revo2 TOUCH PRESSURE (piezoresistive)",true };
    default: return {"UNKNOWN",                             false};
  }
}
static const char* sku_of(uint8_t s) {
  switch (s) { case 1: return "MEDIUM_RIGHT"; case 2: return "MEDIUM_LEFT";
               case 3: return "SMALL_RIGHT";  case 4: return "SMALL_LEFT";
               default: return "UNKNOWN"; }
}
static const char* state_of(uint8_t s) {
  switch (s) { case 0: return "IDLE"; case 1: return "RUN"; case 2: return "STALL";
               case 3: return "TURBO"; default: return "UNK"; }
}
static const StarkFingerId FID[6] = {
  STARK_FINGER_ID_THUMB, STARK_FINGER_ID_THUMB_AUX, STARK_FINGER_ID_INDEX,
  STARK_FINGER_ID_MIDDLE, STARK_FINGER_ID_RING, STARK_FINGER_ID_PINKY };
static const char* FNAME[6] = {"thumb","thumb_aux","index","middle","ring","pinky"};

int main(int argc, char** argv) {
  std::vector<std::string> ports;
  std::vector<uint32_t> bauds = {460800, 115200, 1000000};
  std::vector<uint8_t> ids = {126, 127, 1, 2};
  bool quick = false;

  for (int i = 1; i < argc; ++i) {
    std::string k = argv[i];
    if (k == "--port" && i + 1 < argc) ports.push_back(argv[++i]);
    else if (k == "--baud" && i + 1 < argc) bauds = {(uint32_t)atoi(argv[++i])};
    else if (k == "--slave" && i + 1 < argc) ids = {(uint8_t)atoi(argv[++i])};
    else if (k == "--quick") { quick = true; bauds = {460800}; ids = {126, 127}; }
    else if (k == "-h" || k == "--help") {
      printf("usage: detect_hand [--port /dev/ttyUSBn]... [--baud N] [--slave N] [--quick]\n"
             "  default: scan /dev/ttyUSB0..7 x {460800,115200,1000000} x slave {126,127,1,2}\n"
             "  --quick: 460800 + slave 126/127 only (the factory defaults)\n");
      return 0;
    } else { fprintf(stderr, "unknown arg: %s\n", k.c_str()); return 2; }
  }
  if (ports.empty())
    for (int i = 0; i < 8; ++i) ports.push_back("/dev/ttyUSB" + std::to_string(i));

  init_logging(LOG_LEVEL_ERROR);
  printf("scanning %zu port(s) x %zu baud(s) x %zu slave id(s), read-only%s\n\n",
         ports.size(), bauds.size(), ids.size(), quick ? " [quick]" : "");

  int found = 0;
  for (const auto& p : ports) {
    for (uint32_t b : bauds) {
      DeviceHandler* h = modbus_open(p.c_str(), b);
      if (!h) continue;                       // port absent or busy — not an error
      for (uint8_t id : ids) {
        CDeviceInfo* info = stark_get_device_info(h, id);
        if (!info) continue;
        ++found;
        Model m = model_of(info->hardware_type);
        printf("=============================================================\n");
        printf("  %s  slave %u  @ %u baud\n", p.c_str(), (unsigned)id, b);
        printf("=============================================================\n");
        printf("  model         : %s\n", m.name);
        printf("  hardware_type : %u\n", (unsigned)info->hardware_type);
        printf("  sku           : %u (%s)\n", (unsigned)info->sku_type,
               sku_of(info->sku_type));
        printf("  serial        : %s\n",
               info->serial_number ? info->serial_number : "(null)");
        printf("  firmware      : %s\n",
               info->firmware_version ? info->firmware_version : "(null)");
        free_device_info(info);

        // Ask the hardware instead of trusting the type byte.
        CTouchFingerData* td = stark_get_touch_status(h, id);
        printf("  tactile probe : %s", td ? "DATA RETURNED" : "NULL (no tactile module)");
        if (td && !m.touch) printf("   <-- MISMATCH: type says no touch, but data came back");
        if (!td && m.touch) printf("   <-- MISMATCH: type says touch, but the module is silent");
        printf("\n");
        if (td) {
          for (int f = 0; f < 5; ++f)
            printf("      finger%d normal=%u tangential=%u dir=%u status=0x%04x\n", f,
                   td->items[f].normal_force1, td->items[f].tangential_force1,
                   td->items[f].tangential_direction1, td->items[f].status);
          free_touch_finger_data(td);
        }

        printf("  current limit : ");
        for (int f = 0; f < 6; ++f)
          printf("%u ", stark_get_finger_max_current(h, id, FID[f]));
        printf("mA (max)\n                  ");
        for (int f = 0; f < 6; ++f)
          printf("%u ", stark_get_finger_protected_current(h, id, FID[f]));
        printf("mA (protected)\n");
        printf("  turbo         : %s\n",
               stark_get_turbo_mode_enabled(h, id) ? "ON" : "OFF");

        CMotorStatusData* st = stark_get_motor_status(h, id);
        if (st) {
          printf("  %-10s %8s %8s %8s\n", "finger", "pos", "cur", "state");
          for (int f = 0; f < 6; ++f)
            printf("  %-10s %8u %8d %8s\n", FNAME[f], st->positions[f],
                   st->currents[f], state_of(st->states[f]));
          printf("  (pos 0=open 1000=closed; cur is NORMALIZED -1000..1000,\n"
                 "   multiply by max_current/1000 for mA)\n");
          free_motor_status_data(st);
        } else {
          printf("  motor status  : NULL  <-- device answered ID but not status\n");
        }
        printf("\n");
      }
      modbus_close(h);
    }
  }

  if (!found) {
    printf("NO HAND FOUND.\n"
           "  - is the hand powered? the MCU lives in the hand, not the adapter\n"
           "  - is another process holding the port? (brainco_hand_server, holomotion)\n"
           "      pgrep -af 'brainco_hand_server|udp_to_dds'\n"
           "  - is the user in the dialout group?  id | grep dialout\n"
           "  - Revo2 BASIC has a CAN FD / Modbus-RTU DIP switch under the wrist\n");
    return 1;
  }
  printf("%d hand(s) found.\n", found);
  return 0;
}
