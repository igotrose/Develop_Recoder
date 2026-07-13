# Quectel 4G/5G 通用拨号脚本

这个目录用于合并原来的 4G QMI 和 5G NCM 两套拨号流程。

## 流程

```text
quectel-autoconnect.sh monitor
  -> detect_mode
  -> 5G/NCM: cdc_ncm -> quectel-CM -> DHCP -> route/DNS
  -> 4G/QMI: qmi_wwan + /dev/cdc-wdm0 -> quectel-CM/qmicli -> DHCP -> route/DNS
  -> monitor loop
```

## 判断方式

脚本优先按实际网卡驱动判断：

```text
cdc_ncm  -> 5G/NCM
qmi_wwan -> 4G/QMI
```

如果网卡还没有出现，则按配置中的 USB VID/PID 兜底判断：

```text
QUECTEL_4G_USB_IDS
QUECTEL_5G_USB_IDS
```

当前已将 `2c7c:0900` 作为 5G/NCM 模块 ID 加入默认配置。

也可以通过 `QUECTEL_MODE=4g` 或 `QUECTEL_MODE=5g` 强制指定流程。

## 部署参考

```bash
cp quectel-autoconnect.sh /usr/sbin/
cp quectel-autoconnect /etc/default/
cp quectel-autoconnect.service /lib/systemd/system/
chmod +x /usr/sbin/quectel-autoconnect.sh
systemctl daemon-reload
systemctl enable quectel-autoconnect.service
systemctl restart quectel-autoconnect.service
```
