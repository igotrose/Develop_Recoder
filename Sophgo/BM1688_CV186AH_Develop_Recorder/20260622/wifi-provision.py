#!/usr/bin/env python3
import http.server
import json
import os
import re
import signal
import socketserver
import subprocess
import threading
import time
import urllib.parse

CONFIG = "/etc/wifi-provision/config"
HTML = "/usr/share/wifi-provision/index.html"

CFG = {
    "WIFI_IFACE": "wlan0",
    "WIFI_MODULE": "/mnt/system/ko/rtl8822cu.ko",
    "AP_CON": "ClawStar-Wifi-Setup-AP",
    "AP_SSID": "ClawStar",
    "AP_SSID_SUFFIX": "mac4",
    "AP_SSID_SUFFIX_SEPARATOR": "-",
    "AP_PSK": "12345678",
    "AP_ADDR": "192.168.50.1/24",
    "AP_CHANNEL": "6",
    "WEB_PORT": "12600",
    "CHECK_INTERVAL": "10",
    "FAIL_LIMIT": "3",
    "CONNECT_TIMEOUT": "45",
}

# 读取配置文件
def load_config():
    if not os.path.exists(CONFIG):
        return
    with open(CONFIG, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            CFG[k.strip()] = v.strip()


def run(cmd, timeout=60):
    return subprocess.run(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=timeout,
    )


def out(cmd, timeout=60):
    try:
        return subprocess.check_output(cmd, text=True, timeout=timeout).strip()
    except Exception:
        return ""


def nmcli(*args):
    return run(["nmcli", *args])


def nmout(*args, timeout=60):
    return out(["nmcli", *args], timeout=timeout)


def safe_con_name(ssid):
    name = re.sub(r"[^a-zA-Z0-9_.-]+", "-", ssid).strip("-")
    if not name:
        name = "unknown"
    return "wifi-" + name


def iface_mac_suffix():
    iface = CFG["WIFI_IFACE"]
    path = f"/sys/class/net/{iface}/address"

    try:
        with open(path, "r") as f:
            mac = f.read().strip()
    except OSError:
        return ""

    hex_text = re.sub(r"[^0-9a-fA-F]", "", mac).upper()
    if len(hex_text) < 4:
        return ""

    return hex_text[-4:]


def ap_ssid():
    ssid = CFG["AP_SSID"]

    if CFG.get("AP_SSID_SUFFIX", "").lower() == "mac4":
        suffix = iface_mac_suffix()
        if suffix:
            ssid = ssid + CFG.get("AP_SSID_SUFFIX_SEPARATOR", "-") + suffix

    return ssid


def connection_exists(name):
    names = nmout("-t", "-f", "NAME", "con", "show").splitlines()
    return name in names


def delete_connection(name):
    if connection_exists(name):
        nmcli("con", "delete", name)


def wait_iface():
    iface = CFG["WIFI_IFACE"]
    module = CFG["WIFI_MODULE"]

    if not os.path.exists(f"/sys/class/net/{iface}") and os.path.exists(module):
        run(["insmod", module])

    for _ in range(40):
        if os.path.exists(f"/sys/class/net/{iface}"):
            nmcli("dev", "set", iface, "managed", "yes")
            nmcli("radio", "wifi", "on")
            return True
        time.sleep(1)

    return False


def sta_connected():
    iface = CFG["WIFI_IFACE"]
    state = nmout("-t", "-f", "DEVICE,STATE", "dev")
    return f"{iface}:connected" in state


def scan_wifi():
    iface = CFG["WIFI_IFACE"]

    text = nmout(
        "-t",
        "-e",
        "no",
        "-f",
        "SSID,SIGNAL,SECURITY",
        "dev",
        "wifi",
        "list",
        "ifname",
        iface,
        "--rescan",
        "yes",
        timeout=45,
    )

    aps = {}

    for line in text.splitlines():
        parts = line.split(":")
        if len(parts) < 2:
            continue

        ssid = parts[0].strip()
        if not ssid:
            continue

        try:
            signal_value = int(parts[1])
        except ValueError:
            signal_value = 0

        security = ":".join(parts[2:]).strip() if len(parts) > 2 else ""

        old = aps.get(ssid)
        if old is None or signal_value > old["signal"]:
            aps[ssid] = {
                "ssid": ssid,
                "signal": signal_value,
                "security": security,
            }

    return sorted(aps.values(), key=lambda item: item["signal"], reverse=True)


def get_known_wifi():
    lines = nmout("-t", "-e", "no", "-f", "NAME,TYPE", "con", "show").splitlines()
    known = {}

    for line in lines:
        if ":" not in line:
            continue

        name, typ = line.split(":", 1)
        if typ != "802-11-wireless":
            continue
        if name == CFG["AP_CON"]:
            continue

        ssid = nmout("-g", "802-11-wireless.ssid", "con", "show", name)
        if ssid:
            known[ssid] = name

    return known


def create_ap_connection():
    iface = CFG["WIFI_IFACE"]
    ap_con = CFG["AP_CON"]

    delete_connection(ap_con)

    nmcli(
        "con",
        "add",
        "type",
        "wifi",
        "ifname",
        iface,
        "con-name",
        ap_con,
        "ssid",
        ap_ssid(),
    )

    nmcli(
        "con",
        "modify",
        ap_con,
        "802-11-wireless.mode",
        "ap",
        "802-11-wireless.band",
        "bg",
        "802-11-wireless.channel",
        CFG["AP_CHANNEL"],
        "ipv4.method",
        "shared",
        "ipv4.addresses",
        CFG["AP_ADDR"],
        "ipv6.method",
        "ignore",
        "connection.autoconnect",
        "no",
    )

    if CFG["AP_PSK"]:
        nmcli(
            "con",
            "modify",
            ap_con,
            "wifi-sec.key-mgmt",
            "wpa-psk",
            "wifi-sec.psk",
            CFG["AP_PSK"],
        )


def start_ap():
    print("wifi-provision: start AP")

    create_ap_connection()

    for name in get_known_wifi().values():
        nmcli("con", "down", name)

    nmcli("con", "up", CFG["AP_CON"])


def save_sta_connection(ssid, psk):
    iface = CFG["WIFI_IFACE"]
    con = safe_con_name(ssid)

    delete_connection(con)

    nmcli(
        "con",
        "add",
        "type",
        "wifi",
        "ifname",
        iface,
        "con-name",
        con,
        "ssid",
        ssid,
    )

    nmcli(
        "con",
        "modify",
        con,
        "connection.autoconnect",
        "yes",
        "connection.autoconnect-priority",
        "100",
        "ipv4.method",
        "auto",
        "ipv6.method",
        "ignore",
    )

    if psk:
        nmcli(
            "con",
            "modify",
            con,
            "wifi-sec.key-mgmt",
            "wpa-psk",
            "wifi-sec.psk",
            psk,
        )

    return con


def try_connect(con_name):
    timeout = int(CFG["CONNECT_TIMEOUT"])

    print(f"wifi-provision: try connect {con_name}")

    nmcli("con", "down", CFG["AP_CON"])
    nmcli("con", "up", con_name)

    deadline = time.time() + timeout
    while time.time() < deadline:
        if sta_connected():
            print(f"wifi-provision: connected {con_name}")
            return True
        time.sleep(2)

    nmcli("con", "down", con_name)
    print(f"wifi-provision: connect failed {con_name}")
    return False


def connect_new_wifi(ssid, psk):
    con = save_sta_connection(ssid, psk)

    if try_connect(con):
        return True

    start_ap()
    return False


def connect_best_known():
    scanned = scan_wifi()
    known = get_known_wifi()

    candidates = []
    for ap in scanned:
        ssid = ap["ssid"]
        if ssid in known:
            candidates.append(
                {
                    "ssid": ssid,
                    "con": known[ssid],
                    "signal": ap["signal"],
                }
            )

    candidates.sort(key=lambda item: item["signal"], reverse=True)

    for item in candidates:
        print(
            "wifi-provision: known candidate %s signal=%s"
            % (item["ssid"], item["signal"])
        )
        if try_connect(item["con"]):
            return True

    return False


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/scan":
            data = json.dumps(scan_wifi()).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        if self.path == "/status":
            data = {
                "sta_connected": sta_connected(),
                "known": list(get_known_wifi().keys()),
            }
            body = json.dumps(data).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
            return

        try:
            with open(HTML, "rb") as f:
                body = f.read()
        except OSError as exc:
            body = ("wifi-provision: failed to read %s: %s\n" % (HTML, exc)).encode(
                "utf-8"
            )
            self.send_response(500)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            print(body.decode("utf-8").strip())
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        data = urllib.parse.parse_qs(body)

        if self.path == "/connect":
            ssid = data.get("ssid", [""])[0].strip()
            psk = data.get("psk", [""])[0]

            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"Connecting Wi-Fi, please wait...")

            if ssid:
                threading.Thread(
                    target=connect_new_wifi,
                    args=(ssid, psk),
                    daemon=True,
                ).start()
            return

        self.send_response(404)
        self.end_headers()

    def log_message(self, fmt, *args):
        return


def start_web():
    port = int(CFG["WEB_PORT"])

    class Server(socketserver.TCPServer):
        allow_reuse_address = True

    server = Server(("", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def monitor_loop():
    if not connect_best_known():
        start_ap()

    fail = 0

    while True:
        if sta_connected():
            fail = 0
        else:
            fail += 1
            print(f"wifi-provision: STA not connected, fail={fail}")

            if fail >= int(CFG["FAIL_LIMIT"]):
                print("wifi-provision: try known Wi-Fi before AP fallback")

                if not connect_best_known():
                    print("wifi-provision: no known Wi-Fi connected, fallback AP")
                    start_ap()

                fail = 0

        time.sleep(int(CFG["CHECK_INTERVAL"]))


def main():
    # 导入配置
    load_config()
    # 让 NetworkManager 管理 Wi-Fi 接口，并确保 Wi-Fi 开启
    nmcli("radio", "wifi", "on")

    if not wait_iface():
        raise RuntimeError("%s not found" % CFG["WIFI_IFACE"])

    web = start_web()

    def stop(*_):
        web.shutdown()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    monitor_loop()


if __name__ == "__main__":
    main()
