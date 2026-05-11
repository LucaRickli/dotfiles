# Enterprise WIFI

## Connect

```sh
nmcli connection add type wifi \
  ifname wlan0 \
  con-name enterprise-wifi \
  ssid YOUR_SSID

nmcli connection modify enterprise-wifi \
  wifi-sec.key-mgmt wpa-eap \
  802-1x.eap peap \
  802-1x.identity "your_username" \
  802-1x.password "your_password" \
  802-1x.phase2-auth mschapv2

nmcli connection up enterprise-wifi
```
