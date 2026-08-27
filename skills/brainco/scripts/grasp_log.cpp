// Read-back-and-log grasp current profiler for BrainCo Revo2 (Modbus/RS485).
// Single process: owns the serial port, issues phase commands, samples status.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <chrono>
#include <thread>
#include "stark-sdk.h"

using namespace std::chrono;

static const char* st_name(uint8_t s) {
  switch (s) { case 0: return "IDLE"; case 1: return "RUN";
               case 2: return "STALL"; case 3: return "TURBO"; default: return "UNK"; }
}
static const StarkFingerId FID[6] = {
  STARK_FINGER_ID_THUMB, STARK_FINGER_ID_THUMB_AUX, STARK_FINGER_ID_INDEX,
  STARK_FINGER_ID_MIDDLE, STARK_FINGER_ID_RING, STARK_FINGER_ID_PINKY };

struct Args {
  const char* port = "/dev/ttyUSB3";
  int slave = 127, hz = 100, current_ma = 800, speed = 500;
  int thumb = 550, thumbaux = -1, fingers = 1000;   // thumbaux <0 => hold current pose
  double t_base = 1.0, t_open = 1.5, t_close = 2.5, t_hold = 3.0, t_rel = 2.0;
  const char* out = "/tmp/grasp.csv";
  bool turbo = false, dry = false;
};

int main(int argc, char** argv) {
  Args a;
  for (int i = 1; i < argc; ++i) {
    std::string k = argv[i];
    auto nx = [&]() { return atoi(argv[++i]); };
    if (k == "--port") a.port = argv[++i];
    else if (k == "--slave") a.slave = nx();
    else if (k == "--hz") a.hz = nx();
    else if (k == "--current-ma") a.current_ma = nx();
    else if (k == "--speed") a.speed = nx();
    else if (k == "--thumb") a.thumb = nx();
    else if (k == "--thumbaux") a.thumbaux = nx();
    else if (k == "--fingers") a.fingers = nx();
    else if (k == "--out") a.out = argv[++i];
    else if (k == "--turbo") a.turbo = true;
    else if (k == "--dry") a.dry = true;
    else { fprintf(stderr, "unknown arg %s\n", k.c_str()); return 2; }
  }

  init_logging(LOG_LEVEL_ERROR);
  DeviceHandler* h = modbus_open(a.port, 460800);
  if (!h) { fprintf(stderr, "open %s failed\n", a.port); return 1; }
  CDeviceInfo* info = stark_get_device_info(h, a.slave);
  if (!info) { fprintf(stderr, "no device at slave %d on %s\n", a.slave, a.port); return 1; }
  printf("device: hw=%u sku=%u sn=%s fw=%s\n", (unsigned)info->hardware_type,
         (unsigned)info->sku_type, info->serial_number, info->firmware_version);
  free_device_info(info);

  stark_set_finger_unit_mode(h, a.slave, FINGER_UNIT_MODE_NORMALIZED);
  if (!a.dry) {
    // The hand silently DROPS the first write of a back-to-back burst. Space
    // config writes by >=1 ms or the thumb keeps its old limit. Verified by
    // bisection: 0 ms loses exactly one write per burst, 1 ms is clean.
    auto cfg_gap = [] { std::this_thread::sleep_for(milliseconds(2)); };
    cfg_gap();
    for (int f = 0; f < 6; ++f) {
      stark_set_finger_max_current(h, a.slave, FID[f], (uint16_t)a.current_ma);
      cfg_gap();
      stark_set_finger_protected_current(h, a.slave, FID[f], (uint16_t)a.current_ma);
      cfg_gap();
    }
    stark_set_turbo_mode_enabled(h, a.slave, a.turbo);
    cfg_gap();
  }
  // read back what the device actually accepted
  uint16_t maxc[6];
  printf("max_current readback (mA):");
  for (int f = 0; f < 6; ++f) { maxc[f] = stark_get_finger_max_current(h, a.slave, FID[f]);
                                printf(" %u", maxc[f]); }
  if (!a.dry)
    for (int f = 0; f < 6; ++f)
      if (maxc[f] != (uint16_t)a.current_ma)
        printf("\n  WARNING: finger %d kept %u mA, wanted %d", f, maxc[f], a.current_ma);
  printf("\nturbo=%s  dry_run=%s\n", stark_get_turbo_mode_enabled(h, a.slave) ? "ON" : "OFF",
         a.dry ? "YES (no motion commands will be sent)" : "no");

  CMotorStatusData* m0 = stark_get_motor_status(h, a.slave);
  uint16_t hold_aux = m0 ? m0->positions[1] : 400;
  if (m0) free_motor_status_data(m0);
  uint16_t aux_target = (a.thumbaux < 0) ? hold_aux : (uint16_t)a.thumbaux;

  FILE* fp = fopen(a.out, "w");
  if (!fp) { fprintf(stderr, "cannot write %s\n", a.out); return 1; }
  fprintf(fp, "# port=%s slave=%d hz=%d turbo=%d dry=%d\n",
          a.port, a.slave, a.hz, (int)a.turbo, (int)a.dry);
  fprintf(fp, "# max_current_ma=%u,%u,%u,%u,%u,%u\n",
          maxc[0], maxc[1], maxc[2], maxc[3], maxc[4], maxc[5]);
  fprintf(fp, "# finger_order=thumb,thumb_aux,index,middle,ring,pinky\n");
  fprintf(fp, "t_ms,phase");
  for (int f = 0; f < 6; ++f) fprintf(fp, ",pos%d", f);
  for (int f = 0; f < 6; ++f) fprintf(fp, ",cur%d", f);
  for (int f = 0; f < 6; ++f) fprintf(fp, ",state%d", f);
  fprintf(fp, "\n");

  const double bounds[5] = { a.t_base, a.t_base + a.t_open,
                             a.t_base + a.t_open + a.t_close,
                             a.t_base + a.t_open + a.t_close + a.t_hold,
                             a.t_base + a.t_open + a.t_close + a.t_hold + a.t_rel };
  const char* names[5] = { "baseline", "open", "close", "hold", "release" };
  uint16_t spd[6]; for (int f = 0; f < 6; ++f) spd[f] = (uint16_t)a.speed;
  uint16_t p_open[6]  = { 0, aux_target, 0, 0, 0, 0 };
  uint16_t p_close[6] = { (uint16_t)a.thumb, aux_target, (uint16_t)a.fingers,
                          (uint16_t)a.fingers, (uint16_t)a.fingers, (uint16_t)a.fingers };

  const auto period = microseconds(1000000 / a.hz);
  auto t_start = steady_clock::now();
  int phase = -1; long n = 0;

  while (true) {
    auto now = steady_clock::now();
    double t = duration<double>(now - t_start).count();
    if (t >= bounds[4]) break;
    int ph = 0; while (ph < 4 && t >= bounds[ph]) ++ph;

    if (ph != phase) {           // phase transition: one command, then keep sampling
      phase = ph;
      printf("[%6.2fs] --> %s\n", t, names[ph]); fflush(stdout);
      if (!a.dry) {
        if (ph == 1)      stark_set_finger_positions_and_speeds(h, a.slave, p_open,  spd, 6);
        else if (ph == 2) stark_set_finger_positions_and_speeds(h, a.slave, p_close, spd, 6);
        else if (ph == 4) stark_set_finger_positions_and_speeds(h, a.slave, p_open,  spd, 6);
      }
    }

    CMotorStatusData* m = stark_get_motor_status(h, a.slave);
    if (m) {
      fprintf(fp, "%.1f,%s", t * 1000.0, names[ph]);
      for (int f = 0; f < 6; ++f) fprintf(fp, ",%u", m->positions[f]);
      for (int f = 0; f < 6; ++f) fprintf(fp, ",%d", m->currents[f]);
      for (int f = 0; f < 6; ++f) fprintf(fp, ",%s", st_name(m->states[f]));
      fprintf(fp, "\n");
      free_motor_status_data(m);
      ++n;
    }
    std::this_thread::sleep_until(now + period);
  }

  if (!a.dry) {   // always leave the hand open
    stark_set_finger_positions_and_speeds(h, a.slave, p_open, spd, 6);
    std::this_thread::sleep_for(milliseconds(500));
  }
  fclose(fp);
  modbus_close(h);
  printf("wrote %ld samples -> %s\n", n, a.out);
  return 0;
}
