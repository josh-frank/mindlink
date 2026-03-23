## MindLink

### EDA & polygraph stack for RaspberryPi

Turns your RaspberryPi Grove HAT into an EDA measurement/recording instrument

### Setup & install
```
# Enable i2c
raspi-config nonint do_i2c 0

# Check that your HAT is working
i2cdetect -y -a 1         # should see 04

# on a freshly flashed Pi, from ~/
git clone https://github.com/<…this repo…>
cd mindlink
cp .env.example .env
nano .env                  # set PASSPHRASE at minimum
PASSPHRASE=yourpassphrase sudo bash setup.sh
```

#### Upcoming features
- EDA metering instrument interface: GUI in HTML/JS
- CSV/SRT save function
- timestamping feature
- audio recording
- pulse oximeter, rPPG and other sensors
- machine learning API
