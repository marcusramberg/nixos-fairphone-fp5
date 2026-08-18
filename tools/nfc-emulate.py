#!/usr/bin/env python3
"""
Prototype NFC-A listen / card-emulation driver for the Fairphone 5 (ST21NFCD).

Drives the CLF in raw NCI over the /dev/st21nfc_raw passthrough exposed by the
st21nfc_nci kernel driver. The kernel NCI core must be DOWN (nfc0 disabled)
before running this -- opening the raw node while nfcX is up returns -EBUSY.

Sequence: CORE_RESET -> CORE_INIT -> CORE_SET_CONFIG(listen A) ->
RF_DISCOVER(listen NFC-A). When an external reader energises the field and
selects us, the CLF emits RF_INTF_ACTIVATED_NTF in listen mode; we log it.
The card presents whatever NFCID1 the CLF generates (a 4-byte random UID by
default, first byte 0x08) unless --uid is given. Configure the door reader to
accept that UID (or accept-any).

This is a bring-up tool: it proves listen mode works and shows the activation.
It does not implement a full Type-2 tag (no READ/WRITE responses) -- readers
that only take the UID from anticollision do not need that.

Usage:
    nfc0 down first:  nfctool --device nfc0 --disable   (as root)
    sudo ./nfc-emulate.py [--uid 08:aa:bb:cc] [--verbose]
"""

import argparse
import os
import select
import sys
import time

DEV = "/dev/st21nfc_raw"

# NCI message types (top 3 bits of byte 0)
MT_CMD = 0x20
MT_RSP = 0x40
MT_NTF = 0x60

# GIDs
GID_CORE = 0x00
GID_RF = 0x01
GID_PROP = 0x0F

# Core OIDs
CORE_RESET = 0x00
CORE_INIT = 0x01
CORE_SET_CONFIG = 0x02

# RF OIDs
RF_DISCOVER_MAP = 0x00
RF_DISCOVER = 0x03
RF_INTF_ACTIVATED = 0x05
RF_DEACTIVATE = 0x06

# RF tech-and-mode
NFC_A_PASSIVE_LISTEN = 0x80

# SET_CONFIG parameter IDs (NCI listen-A)
LA_BIT_FRAME_SDD = 0x30
LA_PLATFORM_CONFIG = 0x31
LA_SEL_INFO = 0x32
LA_NFCID1 = 0x33

STATUS_OK = 0x00


def hx(b):
    return " ".join("%02x" % x for x in b)


class Clf:
    def __init__(self, verbose=False):
        self.fd = os.open(DEV, os.O_RDWR)
        self.verbose = verbose
        self.poller = select.poll()
        self.poller.register(self.fd, select.POLLIN)

    def close(self):
        os.close(self.fd)

    def send(self, mt, gid, oid, payload=b""):
        hdr = bytes([mt | gid, oid, len(payload)])
        frame = hdr + payload
        if self.verbose:
            print("TX %s" % hx(frame))
        os.write(self.fd, frame)

    def drain(self, timeout=0.6):
        """Read and discard any unsolicited frames (e.g. the CLF's boot
        notification after reset). The ST CLF NAKs a host write while its IRQ
        is asserted, so pending frames must be consumed before the first CMD."""
        got = 0
        while True:
            f = self.recv(timeout=timeout)
            if f is None:
                return got
            got += 1
            if self.verbose:
                print("drained %s" % hx(f))

    def recv(self, timeout=1.0):
        """Return one NCI frame (bytes) or None on timeout."""
        deadline = time.monotonic() + timeout
        while True:
            rem = deadline - time.monotonic()
            if rem <= 0:
                return None
            if not self.poller.poll(rem * 1000):
                return None
            frame = os.read(self.fd, 260)
            if not frame:
                continue
            if self.verbose:
                print("RX %s" % hx(frame))
            return frame

    def expect(self, mt, gid, oid, timeout=1.0):
        """Wait for a specific frame, skipping proprietary notifications."""
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            f = self.recv(timeout=end - time.monotonic())
            if f is None or len(f) < 3:
                continue
            f_mt, f_gid = f[0] & 0xE0, f[0] & 0x0F
            f_oid = f[1]
            # Silently drop the CLF's proprietary power/field-monitor stream.
            if f_gid == GID_PROP:
                continue
            if f_mt == mt and f_gid == gid and f_oid == oid:
                return f
            if self.verbose:
                print("  (ignored %s)" % hx(f[:3]))
        return None


def core_reset(clf):
    # NCI 2.0 CORE_RESET_CMD: ResetType 0x01 = reset configuration.
    clf.send(MT_CMD, GID_CORE, CORE_RESET, bytes([0x01]))
    rsp = clf.expect(MT_RSP, GID_CORE, CORE_RESET, timeout=1.5)
    if not rsp or rsp[3] != STATUS_OK:
        raise RuntimeError("CORE_RESET failed: %s" % (hx(rsp) if rsp else "timeout"))
    # NCI 2.0 also emits CORE_RESET_NTF with version info.
    ntf = clf.expect(MT_NTF, GID_CORE, CORE_RESET, timeout=1.0)
    if ntf and len(ntf) >= 6:
        print("CLF NCI version 0x%02x, manufacturer 0x%02x" % (ntf[4], ntf[5]))


def core_init(clf):
    # NCI 2.0 CORE_INIT_CMD payload: 2 bytes (feature enables), both zero.
    clf.send(MT_CMD, GID_CORE, CORE_INIT, bytes([0x00, 0x00]))
    rsp = clf.expect(MT_RSP, GID_CORE, CORE_INIT, timeout=1.5)
    if not rsp or rsp[3] != STATUS_OK:
        raise RuntimeError("CORE_INIT failed: %s" % (hx(rsp) if rsp else "timeout"))
    print("CORE_INIT ok (rsp %d bytes)" % len(rsp))
    return rsp


def set_listen_config(clf, uid=None):
    # Build a CORE_SET_CONFIG with the listen-A parameters. SEL_INFO 0x00
    # advertises no ISO-DEP/NFC-DEP, so a reader takes us as a plain NFC-A
    # target and reads the UID from anticollision.
    params = []

    def tlv(pid, val):
        params.append(bytes([pid, len(val)]) + val)

    tlv(LA_BIT_FRAME_SDD, bytes([0x08]))
    tlv(LA_PLATFORM_CONFIG, bytes([0x00]))
    tlv(LA_SEL_INFO, bytes([0x00]))
    if uid is not None:
        # NFCID1: 4, 7 or 10 bytes. A 4-byte fixed UID should normally start
        # 0x08 per NFC Forum; the CLF may enforce this.
        tlv(LA_NFCID1, bytes(uid))

    payload = bytes([len(params)]) + b"".join(params)
    clf.send(MT_CMD, GID_CORE, CORE_SET_CONFIG, payload)
    rsp = clf.expect(MT_RSP, GID_CORE, CORE_SET_CONFIG, timeout=1.5)
    if not rsp:
        raise RuntimeError("SET_CONFIG timeout")
    # rsp: Status, num_invalid_params, [param_ids...]
    if rsp[3] != STATUS_OK:
        bad = rsp[5:] if len(rsp) > 5 else b""
        raise RuntimeError("SET_CONFIG rejected params: %s (status 0x%02x)"
                           % (hx(bad), rsp[3]))
    print("SET_CONFIG ok")


def rf_discover_listen(clf):
    # RF_DISCOVER_CMD: num entries, then (tech_and_mode, frequency) pairs.
    # One entry: NFC-A passive listen, frequency 1.
    payload = bytes([1, NFC_A_PASSIVE_LISTEN, 0x01])
    clf.send(MT_CMD, GID_RF, RF_DISCOVER, payload)
    rsp = clf.expect(MT_RSP, GID_RF, RF_DISCOVER, timeout=1.5)
    if not rsp or rsp[3] != STATUS_OK:
        raise RuntimeError("RF_DISCOVER failed: %s" % (hx(rsp) if rsp else "timeout"))
    print("RF_DISCOVER (listen NFC-A) started")


def parse_uid(s):
    parts = s.replace(":", " ").split()
    return [int(p, 16) for p in parts]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--uid", type=parse_uid, default=None,
                    help="NFCID1 to present, e.g. 08:aa:bb:cc (default: CLF random)")
    ap.add_argument("--verbose", action="store_true", help="dump raw NCI traffic")
    args = ap.parse_args()

    if os.geteuid() != 0:
        sys.exit("must run as root (raw NCI node)")

    try:
        clf = Clf(verbose=args.verbose)
    except OSError as e:
        sys.exit("open %s failed: %s (is nfc0 disabled? EBUSY means nfcX is up)"
                 % (DEV, e))

    try:
        # The CLF was reset when the raw node opened; drain its boot
        # notification before the first command or the write will NAK.
        clf.drain(timeout=0.6)
        core_reset(clf)
        core_init(clf)
        set_listen_config(clf, uid=args.uid)
        rf_discover_listen(clf)

        print("Listening. Present phone to a reader (Ctrl-C to stop)...")
        while True:
            f = clf.recv(timeout=5.0)
            if f is None:
                continue
            mt, gid, oid = f[0] & 0xE0, f[0] & 0x0F, f[1]
            if gid == GID_PROP:
                continue
            if mt == MT_NTF and gid == GID_RF and oid == RF_INTF_ACTIVATED:
                print(">>> ACTIVATED in listen mode (reader selected us)")
                print("    %s" % hx(f))
            elif mt == MT_NTF and gid == GID_RF and oid == RF_DEACTIVATE:
                print("<<< deactivated (reader left field)")
            else:
                print("NTF %s" % hx(f))
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        clf.close()


if __name__ == "__main__":
    main()
