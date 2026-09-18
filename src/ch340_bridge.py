#!/data/data/com.termux/files/usr/bin/python3
"""
CH340 (1a86:7523) userspace serial driver + PTY bridge for Termux.

Bridges a real tty (pty) to the CH340 USB-serial chip using pyusb, so that
pyserial / stcgal can talk to an STC 8051 board on non-rooted Android.

Run under termux-usb, e.g.:
    termux-usb -r -E -e ./ch340_bridge.py /dev/bus/usb/001/004
It prints the /dev/pts/N path, then keep it running and use that path with
stcgal in another session.
"""

import os
import sys
import pty
import tty
import termios
import select
import fcntl
import struct
import time
import threading
import traceback

try:
    import usb.core
    import usb.util
except ImportError:
    sys.exit("pyusb is required: pip install pyusb")

VID = 0x1A86
PID = 0x7523

EP_OUT = 0x02
EP_IN = 0x82

CH341_REQ_READ_VERSION = 0x5F
CH341_REQ_WRITE_REG = 0x9A
CH341_REQ_READ_REG = 0x95
CH341_REQ_SERIAL_INIT = 0xA1
CH341_REQ_MODEM_CTRL = 0xA4

CH341_REG_PRESCALER = 0x12
CH341_REG_DIVISOR = 0x13
CH341_REG_LCR = 0x18
CH341_REG_LCR2 = 0x25
CH341_REG_FLOW_CTL = 0x27

CH341_LCR_ENABLE_RX = 0x80
CH341_LCR_ENABLE_TX = 0x40
CH341_LCR_CS8 = 0x03

CH341_BIT_RTS = 1 << 6
CH341_BIT_DTR = 1 << 5

CH341_CLKRATE = 48000000
# 注意：下面两个边界沿用了内核驱动的写法，MAX_BPS 实际只有 46875，
# 于是 57600/115200 会被静默截断成 46875（实测 get_divisor(115200) == 0x8003，
# 而不是 WCH 驱动里的 0xCC83）。本项目固定用 2400，不受影响。
# 详见 docs/DEBUG_LOG.md「#14 115200 的第二个坑」。
MIN_BPS = (CH341_CLKRATE + (1 << 12) * 256 - 1) // ((1 << 12) * 256)
MAX_BPS = CH341_CLKRATE // ((1 << 9) * 2)

BAUD_MAP = {}
for _name in dir(termios):
    if _name.startswith("B") and _name[1:].isdigit():
        BAUD_MAP[getattr(termios, _name)] = int(_name[1:])


def log(msg):
    print("[ch340] %s" % msg, file=sys.stderr, flush=True)


def clk_div(ps, fact):
    return 1 << (12 - 3 * ps - fact)


def min_rate(ps):
    return CH341_CLKRATE / (clk_div(ps, 1) * 512)


def get_divisor(speed):
    speed = int(max(MIN_BPS, min(MAX_BPS, speed)))
    ps = -1
    for p in range(3, -1, -1):
        if speed > min_rate(p):
            ps = p
            break
    if ps < 0:
        raise ValueError("baud out of range")
    fact = 1
    cdiv = clk_div(ps, fact)
    div = CH341_CLKRATE // (cdiv * speed)
    if div < 9 or div > 255:
        div //= 2
        cdiv *= 2
        fact = 0
    if div < 2:
        raise ValueError("baud out of range")
    a = 16 * CH341_CLKRATE // (cdiv * div)
    b = 16 * CH341_CLKRATE // (cdiv * (div + 1))
    if a - 16 * speed >= 16 * speed - b:
        div += 1
    if fact == 1 and div % 2 == 0:
        div //= 2
        fact = 0
    return (0x100 - div) << 8 | fact << 2 | ps


class Ch340:
    def __init__(self):
        self.dev = None
        self.version = 0
        self.lcr = CH341_LCR_ENABLE_RX | CH341_LCR_ENABLE_TX | CH341_LCR_CS8
        self.baud = 9600
        self.mcr = 0
        self.lock = threading.Lock()

    def control_out(self, request, value, index):
        self.dev.ctrl_transfer(0x40, request, value, index, None, timeout=1000)

    def control_in(self, request, value, index, size):
        return bytes(self.dev.ctrl_transfer(0xC0, request, value, index, size,
                                            timeout=1000))

    def open(self):
        dev = usb.core.find(idVendor=VID, idProduct=PID)
        if dev is None:
            devs = list(usb.core.find(find_all=True))
            found = ", ".join("%04x:%04x" % (d.idVendor, d.idProduct)
                              for d in devs) or "none"
            raise RuntimeError("not a CH340 (found %s)" % found)
        self.dev = dev
        try:
            if dev.is_kernel_driver_active(0):
                dev.detach_kernel_driver(0)
        except Exception:
            pass
        try:
            dev.set_configuration()
        except usb.core.USBError:
            pass
        try:
            usb.util.claim_interface(dev, 0)
        except usb.core.USBError as e:
            log("claim_interface failed: %s" % e)
        self.version = self.control_in(CH341_REQ_READ_VERSION, 0, 0, 2)[0]
        log("chip version 0x%02x" % self.version)
        self.control_out(CH341_REQ_SERIAL_INIT, 0, 0)
        self.set_baud(self.baud)
        self.set_handshake(self.mcr)

    def set_baud(self, baud):
        try:
            val = get_divisor(baud)
        except ValueError:
            log("unsupported baud %s" % baud)
            return
        if self.version > 0x27:
            val |= 0x80
        with self.lock:
            self.control_out(CH341_REQ_WRITE_REG,
                             (CH341_REG_DIVISOR << 8) | CH341_REG_PRESCALER,
                             val)
            if self.version >= 0x30:
                self.control_out(CH341_REQ_WRITE_REG,
                                 (CH341_REG_LCR2 << 8) | CH341_REG_LCR,
                                 self.lcr)
        if baud != self.baud:
            log("baud -> %s" % baud)
        self.baud = baud

    def set_handshake(self, mcr):
        if mcr == self.mcr and getattr(self, "_hs_done", False):
            return
        with self.lock:
            self.control_out(CH341_REQ_MODEM_CTRL, (~mcr) & 0xFFFF, 0)
        self.mcr = mcr
        self._hs_done = True

    def write(self, data):
        for i in range(0, len(data), 32):
            self.dev.write(EP_OUT, data[i:i + 32], timeout=1000)

    def read(self, size=64, timeout=100):
        return self.dev.read(EP_IN, size, timeout=timeout)


def run(test_only=False):
    if len(sys.argv) > 1 and sys.argv[1].isdigit():
        # termux-usb -e 会把设备 fd 作为参数传给本脚本
        os.environ.setdefault("TERMUX_USB_FD", str(int(sys.argv[1])))

    chip = Ch340()
    chip.open()

    if test_only:
        log("configure ok, sending 0x55...")
        chip.write(b"\x55")
        try:
            d = chip.read(64, timeout=500)
            log("read back: %s" % bytes(d).hex())
        except usb.core.USBError as e:
            log("read: %s" % e)
        return

    master, slave = pty.openpty()
    tty.setraw(master)
    tty.setraw(slave)
    slave_name = os.ttyname(slave)
    os.set_blocking(master, False)
    try:
        fcntl.ioctl(master, termios.TIOCSWINSZ,
                    struct.pack("HHHH", 24, 80, 0, 0))
    except OSError:
        pass

    base = os.path.dirname(os.path.abspath(__file__))
    try:
        with open(os.path.join(base, ".ch340_pts"), "w") as f:
            f.write(slave_name)
        with open(os.path.join(base, ".ch340_bridge.pid"), "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass
    print(slave_name, flush=True)
    log("虚拟串口已创建: %s（保持本进程运行）" % slave_name)

    running = True
    pending = bytearray()
    state = {"baud": None, "mcr": None}

    def usb_reader():
        while running:
            try:
                data = chip.read(64, timeout=100)
            except usb.core.USBError as e:
                if e.errno == 110 or "timeout" in str(e).lower():
                    data = None
                else:
                    time.sleep(0.05)
                    continue
            except Exception:
                time.sleep(0.05)
                continue
            if data:
                pending.extend(bytes(data))
            while pending and running:
                try:
                    n = os.write(master, bytes(pending))
                    del pending[:n]
                except BlockingIOError:
                    break
                except OSError:
                    del pending[:]
                    break

    def pty_reader():
        while running:
            try:
                r, _, _ = select.select([master], [], [], 0.1)
            except (OSError, ValueError):
                continue
            if master in r:
                try:
                    data = os.read(master, 4096)
                except BlockingIOError:
                    continue
                except OSError:
                    time.sleep(0.05)
                    continue
                if data:
                    try:
                        chip.write(data)
                    except usb.core.USBError as e:
                        log("usb write error: %s" % e)

    def monitor():
        while running:
            try:
                attrs = termios.tcgetattr(master)
            except OSError:
                time.sleep(0.1)
                continue
            spd = attrs[5] or attrs[4]
            baud = BAUD_MAP.get(spd)
            if baud and baud != state["baud"]:
                state["baud"] = baud
                chip.set_baud(baud)
            mcr = 0
            try:
                bits = struct.unpack("I", fcntl.ioctl(
                    master, termios.TIOCMGET, struct.pack("I", 0)))[0]
                if bits & termios.TIOCM_DTR:
                    mcr |= CH341_BIT_DTR
                if bits & termios.TIOCM_RTS:
                    mcr |= CH341_BIT_RTS
            except OSError:
                pass
            if mcr != state["mcr"]:
                state["mcr"] = mcr
                chip.set_handshake(mcr)
            time.sleep(0.003)

    threads = [
        threading.Thread(target=usb_reader, daemon=True),
        threading.Thread(target=pty_reader, daemon=True),
        threading.Thread(target=monitor, daemon=True),
    ]
    for t in threads:
        t.start()

    try:
        while True:
            time.sleep(0.5)
    except KeyboardInterrupt:
        running = False
        print("\n退出桥接。", file=sys.stderr)
    finally:
        running = False
        time.sleep(0.1)
        try:
            usb.util.release_interface(chip.dev, 0)
        except Exception:
            pass


if __name__ == "__main__":
    try:
        run(test_only="--test" in sys.argv)
    except Exception:
        traceback.print_exc()
        sys.exit(1)
