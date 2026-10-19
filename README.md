# Exhale

An iOS app for Tuya / Smart Life air purifiers (built for a Guardian purifier). PM2.5 front and centre, a smooth colour-graded history graph in the style of the Blueair app, and home-screen and lock-screen widgets with a working power button.

## Features

Live PM2.5 with the EPA 2024 bands (Good, Moderate, Sensitive, Unhealthy, Very unhealthy, Hazardous). History graph for 24 h / 7 d / 30 d with a smooth curve whose colour follows the air quality, drag to scrub, plus average, peak and percent of time in Good. Power, fan speed, mode, ionizer, UV, child lock, display light, timer and filter life with reset, shown only when your unit reports them. Any other writable data point the purifier exposes appears under More, so nothing is hidden. Temperature, humidity, TVOC, CO2 and other sensors if the model has them.

Widgets: small (PM2.5 + power), medium (PM2.5 + last 12 h graph), large (bigger graph with band lines), and lock screen circular, rectangular and inline. Shortcuts actions: Toggle Air Purifier, Set Air Purifier Power, Get Air Quality.

## Signing in

Exhale uses the Smart Life sharing login that Home Assistant's built-in Tuya integration uses. No Tuya developer account.

1. In Smart Life: Me, the settings gear, Account and Security, User Code. Copy it.
2. Paste it into Exhale and tap Get login QR.
3. Save the QR to Photos, open Smart Life, tap + then Scan, tap the photo icon, pick the QR and confirm. (Or scan it from a second device.)

Exhale appears as a linked "Home Assistant" login in your Smart Life account.

## History

Tuya's sharing API has no history endpoint, so readings are logged on the phone: every 20 s while the app is open, and on each widget refresh or background app refresh (roughly every 15 to 30 minutes, iOS decides). Keep a widget on a home screen and the graph stays filled in. The last 48 h are kept at about one reading per minute; older data is rolled into 10-minute averages and kept for 45 days.

## Build

Push to `main` (or run the workflow manually) and GitHub Actions builds `Exhale.ipa` and publishes it as a release. The app and widget are ad-hoc signed with the `group.com.soum91.exhale` App Group so the widget can read the login and readings. Sideload with AltStore, SideStore or Sideloadly with app extensions kept. If Settings shows "Widget data sharing: Not available", the sideloader stripped the App Group.

Local build: `brew install xcodegen && xcodegen generate`, then open `Exhale.xcodeproj`.

## How it talks to the cloud

Login: `POST apigw.iotbing.com/v1.0/m/life/home-assistant/qrcode/tokens` with the user code, show `tuyaSmart--qrLogin?token=…`, poll `GET …/qrcode/tokens/{token}` until Smart Life confirms. That returns an access token, refresh token and the regional endpoint.

Every call after that is signed: random request id, `hashKey = md5(rid + refreshToken)`, AES key = first 16 hex chars of `HMAC-SHA256(rid, hashKey)`, query and body sent AES-GCM encrypted as `encdata`, headers signed with `HMAC-SHA256(hashKey, "X-appKey=…||X-requestId=…||X-time=…||X-token=…" + encdata)`. Responses come back encrypted with the same key.

Endpoints: `/v1.0/m/life/users/homes`, `/v1.0/m/life/ha/home/devices`, `/v1.0/m/life/ha/devices/detail`, `/v1.1/m/life/{id}/specifications`, `/v1.1/m/thing/{id}/commands`, token refresh at `/v1.0/m/token/{refreshToken}`.

Protocol from [tuya/tuya-device-sharing-sdk](https://github.com/tuya/tuya-device-sharing-sdk) and Home Assistant's Tuya integration. Independent Swift implementation, not affiliated with Tuya. Unofficial use of their API; it can change.
