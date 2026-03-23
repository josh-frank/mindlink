## MindLink

*An EDA & polygraph stack for RaspberryPi*
Turn your RaspberryPi Grove HAT into an EDA instrument

### Setup & install
```
# on a freshly flashed Pi, from ~/
raspi-config nonint do_i2c 0  # Enable i2c
i2cdetect -y -a 1             # HAT working? Should see 04
git clone https://github.com/<…this repo…>
cd mindlink
cp .env.example .env
nano .env                     # set PASSPHRASE at minimum
PASSPHRASE=<…> sudo bash setup.sh
```

### Upcoming features
- EDA metering instrument interface: GUI in HTML/JS
- CSV/SRT save function
- timestamping feature
- audio recording
- pulse oximeter, rPPG and other sensors
- machine learning API
