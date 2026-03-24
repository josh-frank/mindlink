## MindLink

*An EDA & polygraph stack for RaspberryPi*

### Setup & install
```
# on a fresh-baked RaspberryPi, from ~/
apt install git python3-pip

apt-get install i2c-tools
raspi-config nonint do_i2c 0  # Enable i2c
i2cdetect -y -a 1             # HAT working? Should see 04

git clone https://github.com/<…this repo…>
cd mindlink
cp .env.example .env
nano .env                     # set PASSPHRASE at minimum
MINDLINK_USER=<…> PASSPHRASE=<…> sudo bash setup.sh

# after reboot, connect via WiFi with SSID from .env
┌──────────────────────────────────────────┐
│  Stream : ws://192.168.4.1:5000          │
│  HTTP   : http://192.168.4.1:5001/frame  │
│           http://192.168.4.1:5001/info   │
└──────────────────────────────────────────┘
```

### Upcoming features
- EDA metering instrument interface: GUI in HTML/JS
- CSV/SRT save function
- timestamping feature
- audio recording
- pulse oximeter, rPPG and other sensors
- machine learning API
