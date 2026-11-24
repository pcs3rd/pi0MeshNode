// t114ctl: set the status-LED brightness on Heltec T114 CH341 bridges (github.com/pcs3rd/t114-ch341).
//
//   t114ctl [-s SERIAL] brightness        print the current brightness
//   t114ctl [-s SERIAL] brightness N      set it (0-255, 0 = off)
//
// Talks to every attached bridge, or only the one with SERIAL. A bridge is identified by
// 1a86:5512 *and* a product string containing "T114", so real CH341 MeshSticks are never sent
// these vendor requests. Works while meshtasticd has the bridge open: the requests go to the
// device, not to the interface meshtasticd claims.
#include <libusb-1.0/libusb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VID 0x1A86
#define PID 0x5512
#define REQ_BRIGHTNESS 0xF8

static int usage(void) {
  fprintf(stderr, "usage: t114ctl [-s SERIAL] brightness [0-255]\n");
  return 2;
}

int main(int argc, char **argv) {
  const char *want_serial = NULL;
  int argi = 1;
  if (argi + 1 < argc && strcmp(argv[argi], "-s") == 0) {
    want_serial = argv[argi + 1];
    argi += 2;
  }
  if (argi >= argc || strcmp(argv[argi], "brightness") != 0) return usage();
  argi++;
  int set = -1;
  if (argi < argc) {
    char *end;
    long v = strtol(argv[argi], &end, 10);
    if (*end || v < 0 || v > 255) return usage();
    set = (int)v;
    argi++;
  }
  if (argi != argc) return usage();

  if (libusb_init(NULL) != 0) {
    fprintf(stderr, "t114ctl: libusb_init failed\n");
    return 1;
  }
  libusb_device **list;
  ssize_t n = libusb_get_device_list(NULL, &list);
  int found = 0, failed = 0;

  for (ssize_t i = 0; i < n; i++) {
    struct libusb_device_descriptor d;
    if (libusb_get_device_descriptor(list[i], &d) != 0 || d.idVendor != VID || d.idProduct != PID) continue;
    libusb_device_handle *h;
    if (libusb_open(list[i], &h) != 0) continue;  // e.g. no permission, or not passed into a container

    unsigned char product[64] = "", serial[16] = "";
    if (d.iProduct) libusb_get_string_descriptor_ascii(h, d.iProduct, product, sizeof(product));
    if (d.iSerialNumber) libusb_get_string_descriptor_ascii(h, d.iSerialNumber, serial, sizeof(serial));
    if (!strstr((char *)product, "T114") || (want_serial && strcmp((char *)serial, want_serial) != 0)) {
      libusb_close(h);
      continue;
    }
    found++;

    int r = 0;
    if (set >= 0) {
      r = libusb_control_transfer(h, LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_DEVICE | LIBUSB_ENDPOINT_OUT,
                                  REQ_BRIGHTNESS, (uint16_t)set, 0, NULL, 0, 1000);
    }
    unsigned char level = 0;
    if (r >= 0) {
      r = libusb_control_transfer(h, LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_DEVICE | LIBUSB_ENDPOINT_IN,
                                  REQ_BRIGHTNESS, 0, 0, &level, 1, 1000);
    }
    if (r < 0) {
      fprintf(stderr, "t114ctl: %s: %s\n", serial, libusb_error_name(r));
      failed++;
    } else {
      printf("%s: brightness %u\n", serial, level);
    }
    libusb_close(h);
  }
  libusb_free_device_list(list, 1);
  libusb_exit(NULL);

  if (!found) {
    fprintf(stderr, "t114ctl: no T114 CH341 bridge found%s%s\n", want_serial ? " with serial " : "",
            want_serial ? want_serial : "");
    return 1;
  }
  return failed ? 1 : 0;
}
