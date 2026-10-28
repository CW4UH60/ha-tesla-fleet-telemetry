# Tesla Fleet Telemetry for Home Assistant

A custom Home Assistant integration that consumes Tesla's
[Fleet Telemetry](https://developer.tesla.com/docs/fleet-api/fleet-telemetry)
push stream — an mTLS WebSocket carrying Protobuf-in-FlatBuffers frames — and
surfaces the vehicle's live state as Home Assistant entities.

Unlike a polled integration, the vehicle *pushes* updates: location and speed
arrive every few seconds while the car is awake, and discrete events (doors,
locks, charging state) arrive the moment they change.

> **This is an advanced integration.** Tesla delivers Fleet Telemetry only to
> a publicly reachable endpoint that terminates mutual TLS. This fork includes
> a Home Assistant add-on that provides that endpoint, but its TCP port must be
> forwarded through your router and its hostname must resolve directly to your
> public IP. If you only want polled climate/charging/door
> data with no infrastructure to manage, use the official
> [`tesla_fleet`](https://www.home-assistant.io/integrations/tesla_fleet/)
> integration instead.

This integration **complements** `tesla_fleet`: run both side by side and the
telemetry entities give you a real-time mirror of the polled ones. It is
read-only apart from one opt-in command, `tesla_telemetry.navigate`, which
sends a destination to the car's navigation and is off until you enable it
(see [Services](#services)).

## Entities

One Home Assistant **device per vehicle**, carrying 47 entities by default.
Add the integration once per VIN to track multiple cars. Each signal you add
from the catalog adds one more sensor (see [Choosing signals](#choosing-signals)).

| Platform | Count | Examples |
| --- | --- | --- |
| `device_tracker` | 2 | Location, Route (active nav destination) |
| `sensor` | 30 | Speed, State of charge, Charging state, Inside temperature, Motor stator temperatures, Signals received |
| `binary_sensor` | 15 | Doors ×6, Windows ×4, Lock, Charge port door, Charge cable, Charging, User present |

<details>
<summary>Full entity list</summary>

**Device trackers**: Location (with a `heading` attribute), Route

**Sensors**
* *Driving & navigation*: Speed, Heading, Gear, Distance to arrival,
  Time to arrival
* *Battery & range*: Battery level, State of charge, Battery range,
  Rated range
* *Charging*: Charging state, AC charging power, DC charging power,
  AC charge energy added, DC charge energy added, Fast charger type,
  Charging cable, Charge limit, Time to full charge
* *Climate*: Inside temperature, Outside temperature
* *Software update*: Software version, Software update download,
  Software update install
* *Powertrain & thermal*: Front motor stator temperature, Rear motor stator
  temperature, Battery temperature (max), Battery temperature (min),
  Battery temperature (avg, calculated)
* *Diagnostic*: Signals received, Estimated signal cost

**Binary sensors**: Front/rear driver/passenger doors, Frunk, Trunk,
Front/rear driver/passenger windows, Lock, Charge port door, Charge cable,
Charging, User present

Rear-wheel-drive cars only report the rear drive unit, so *Front motor stator
temperature* stays unknown on them.

</details>

Entity IDs follow the vehicle's name, e.g. `sensor.<vehicle>_speed`,
`device_tracker.<vehicle>_location`.

## How it works

```
┌──────────┐  mTLS WSS   ┌────────────────┐  verified WS  ┌────────────────┐
│  Tesla   │ ──────────► │ Receiver add-on│ ─────────────► │ Home Assistant │
│ Vehicle  │             │ (nginx + certs)│                │ /api/tesla_    │
│ (Hermes) │             └────────────────┘                │ telemetry/ws   │
└──────────┘                                               └────────────────┘
```

* **Small, local receiver.** The companion add-on terminates mTLS, validates
  Tesla's vehicle certificate, and forwards the WebSocket to Home Assistant's
  own HTTP server. The integration registers a view at
  `/api/tesla_telemetry/ws`.
* **OAuth via `application_credentials`.** Home Assistant Core owns the Tesla
  OAuth token lifecycle. Each integration instance gets its own grant — no
  refresh-token contention with `tesla_fleet`.
* **`Tesla.SS256` JWT signing.** Tesla's `fleet_telemetry_config_jws` endpoint
  requires a JWT signed with RFC 8235 Schnorr over P-256. The signer is
  implemented in `crypto.py`.
* **FlatBuffers + Protobuf decoding.** Tesla wraps Protobuf payloads in a
  FlatBuffers envelope; the generated bindings are vendored under `proto/`.

## Requirements

* Home Assistant **2024.12** or later.
* A **Tesla developer account** with a registered *partner application*
  ([developer.tesla.com](https://developer.tesla.com/)). North America and
  Europe are supported — pick the region at the start of the config flow.
  (China is excluded, as in HA core's tesla_fleet: separate infrastructure,
  untested.)
* An **EC P-256 (secp256r1) partner key pair**, with the public key hosted at
  `https://<partner-domain>/.well-known/appspecific/com.tesla.3p.public-key.pem`.
* A **publicly reachable TCP port** forwarded to the receiver add-on, which:
  * presents a valid TLS server certificate,
  * terminates mutual TLS, verifying the vehicle's client certificate against
    Tesla's fleet CA,
  * proxies the WebSocket upgrade to Home Assistant,
  * injects the `X-Tesla-Proxy-Secret` and `X-Tesla-Verified-Vin` headers.
* Python packages `protobuf` and `flatbuffers`, declared in `manifest.json`
  and installed automatically by Home Assistant (`cryptography` ships with
  Home Assistant itself).

## Setup

### 1. Tesla developer / partner application

1. Create an application at [developer.tesla.com](https://developer.tesla.com/).
   Note the **client ID** and **client secret**.
2. Add `https://my.home-assistant.io/redirect/oauth` to the application's
   **Allowed Redirect URIs** (Home Assistant's OAuth flow uses it).
3. Request the scopes `openid`, `offline_access`, `vehicle_device_data`, and
   `vehicle_location` (newer developer apps need `vehicle_location` for the
   location signals; without it `bootstrap` fails with a 403).
4. Generate the partner key pair and host its public half:
   ```sh
   openssl ecparam -genkey -name prime256v1 -noout -out partner.key
   openssl ec -in partner.key -pubout -out public-key.pem
   ```
   Publish `public-key.pem` at
   `https://<partner-domain>/.well-known/appspecific/com.tesla.3p.public-key.pem`.
   Keep `partner.key` — you paste it into Home Assistant later.

### 2. Receiver add-on and network path

1. Add this repository to **Settings → Add-ons → Add-on store → Repositories**:
   `https://github.com/CW4UH60/ha-tesla-fleet-telemetry`.
2. Install **Tesla Fleet Telemetry Receiver**.
3. Set a dedicated hostname, a 64-character random proxy secret, and port
   `4443`. Start the add-on once so it creates
   `/ssl/tesla-telemetry/ca.crt` and its private server key.
4. Create a DNS-only record for the hostname pointing at your public IP. Do
   not proxy this record through a normal Cloudflare Tunnel: Tesla connects
   with raw mutual TLS.
5. Forward TCP `4443` on the router to TCP `4443` on the Home Assistant host.

The add-on downloads Tesla's production vehicle CA from a pinned commit of
[`teslamotors/fleet-telemetry`](https://github.com/teslamotors/fleet-telemetry)
and verifies its SHA-256 during the image build. Its own receiver CA and keys
stay in `/ssl/tesla-telemetry`; hostname changes are backed up before
certificates are rotated.

> **Keep the proxy secret secret.** `/api/tesla_telemetry/ws` is served by
> Home Assistant's own HTTP server, so it is reachable wherever Home Assistant
> is — not only through nginx — and Home Assistant does not ask for a login on
> it. The secret is what tells a real, mTLS-verified vehicle connection apart
> from anyone else claiming a VIN (VINs are not secret). Don't publish the
> add-on config, and if the secret leaks, rotate it in both places. The add-on
> get a new one. `proxy_set_header` replaces any `X-Tesla-*` header a client
> sends, so nginx itself can't be used to forge them.

### 3. Install the integration

[![Open this repository in HACS](https://my.home-assistant.io/badges/hacs_repository.svg)](https://my.home-assistant.io/redirect/hacs_repository/?owner=CW4UH60&repository=ha-tesla-fleet-telemetry&category=integration)

1. In HACS, search for **Tesla Fleet Telemetry** and download it (or use the
   button above).
2. Restart Home Assistant.

If your HACS doesn't list it, add it as a custom repository first: HACS → ⋯ →
**Custom repositories** → `https://github.com/CW4UH60/ha-tesla-fleet-telemetry`,
type *Integration*, then continue from step 1.

(Manual install: copy `custom_components/tesla_telemetry` into your Home
Assistant `config/custom_components/` directory and restart.)

### 4. Configure in Home Assistant

1. **Settings → Devices & Services → Application Credentials** — add the Tesla
   **client ID** and **client secret** from step 1.
2. **Settings → Devices & Services → Add Integration → Tesla Fleet Telemetry.**
3. Complete the Tesla OAuth login, then pick the **VIN** to track.
4. On the **endpoint** step, enter:
   * the public **hostname** and **port** the receiver add-on listens on,
   * the **partner domain** hosting your `.well-known` public key,
   * the **proxy secret** (the same value used by the add-on),
   * **Reuse the existing Home Assistant Tesla Fleet partner key** when the
     official integration already created `/config/tesla_fleet.key`; otherwise
     provide the partner private key from step 1.

### 5. Bootstrap and verify

1. Run the **`tesla_telemetry.bootstrap`** service once. It registers your
   partner domain with Tesla and pushes the initial telemetry configuration.
2. Run **`tesla_telemetry.get_telemetry_config`** and confirm `synced: true`
   in the response. Tesla's `synced` flag can lag several minutes behind a
   successful push.
3. Wake the vehicle (open the Tesla app) and watch the receiver add-on log for
   a successful WebSocket connection. Entities begin updating shortly after.

## Choosing signals

The integration streams a curated default set of signals. To change it, open
**Settings → Devices & Services → Tesla Fleet Telemetry → Configure**. No
update or restart is needed, and saving re-pushes the config to the car.

* **Retune**: each signal's value is the minimum number of seconds between
  updates. Tesla sends a signal when it changes, and no more often than that.
* **Disable**: set a signal to `0`.
* **Add**: under *Add signals from the full Tesla catalog*, pick any signal.
  It streams at 60 s, and its interval then appears under *Additional signals*.

Each added signal gets a **generic sensor** named after it, such as
`sensor.<vehicle>_sentry_mode`. Its state is decoded from what the car sends:
numbers become measurements that chart and feed long-term statistics, enums
become friendly text (`armed`), booleans become `on`/`off`, and composite
values (location, doors, …) become a summary with each field as an attribute.
The `value_type` attribute shows which kind arrived. Setting an added signal
back to `0` removes its sensor.

Generic sensors have no unit. To add one, use HA's customize:

```yaml
homeassistant:
  customize:
    sensor.my_car_odometer:
      unit_of_measurement: mi
      device_class: distance
```

Notes:

* **Billing**: every streamed datum counts toward Tesla's signal bill. Watch
  *Signals received* → `by_signal` after you add something.
* **Older and newer vehicles**: support differs by model year and firmware.
  Pre-2021 Model S/X may never report some catalog signals; their sensors
  stay `unknown`, and that costs nothing. If Tesla rejects the whole config
  for a vehicle (e.g. `unsupported_firmware`), a warning is logged.
* Signals are chosen per vehicle, so each car can stream a different set.

## Multiple vehicles

Add the integration again for each additional VIN. The endpoint settings
(hostname, proxy secret, partner key) are deployment-wide, so the endpoint
step is pre-filled from your first vehicle — just confirm it. Each VIN becomes
its own Home Assistant device with its own entities. Service calls take an
`entry_id` to select the vehicle when more than one is configured.

## Services

All services except `navigate` are **admin-only**: they change what the car
streams (and so what Tesla bills), the CA it trusts, or expose the partner
setup.

| Service | Purpose |
| --- | --- |
| `tesla_telemetry.bootstrap` | One-time onboarding: register the partner domain and push the initial config. |
| `tesla_telemetry.resync_telemetry_config` | Re-push the config. Runs automatically (the config's `exp` is ~30 days); rarely needed by hand. |
| `tesla_telemetry.get_telemetry_config` | Fetch Tesla's current config for the VIN — check `synced`. |
| `tesla_telemetry.dump_public_key` | Emit the partner public key PEM, ready to host at `.well-known`. |
| `tesla_telemetry.set_interval_preset` | Switch streaming intervals between `default` and `high_rate` (~1 s location/speed). |
| `tesla_telemetry.navigate` | Send a destination to the car's navigation: free text (`destination`) or `latitude`/`longitude`. Off until *Allow vehicle commands* is turned on in the options. |

`navigate` is the integration's only write to the vehicle, and it is **off
unless you turn it on**: *Settings → Devices & services → Tesla Fleet Telemetry
→ Configure → Vehicle commands → Allow vehicle commands*. Free text goes out as
Tesla's `navigation_request`, the same command as sharing a location from the
Tesla phone app, so the car looks the text up itself (`locale`, default
`en-US`, sets the language it reads it in); coordinates go out as
`navigation_gps_request`, with an optional `order` (0 = car decides, 1 =
replace the trip, 2 = next stop, 3 = last stop). It needs:

* the **`vehicle_cmds` scope** in the entry's token. Setup asks Tesla only for
  read access (`vehicle_device_data`); turning the option on checks the token
  and, if the scope is missing, starts a **re-authentication** (Settings →
  Devices & services shows it) that asks for `vehicle_cmds` too. Your Tesla
  developer app must be approved for vehicle commands. Tesla issues a token
  with every scope the account has granted that app, so an account that
  authorized the same app through HA's `tesla_fleet` may already have it and
  need no re-auth.
* a vehicle that accepts **unsigned Fleet API commands**, i.e. pre-2021
  Model S/X. Newer vehicles require Tesla's signed Vehicle Command Protocol,
  which this integration does not implement.
* an **awake** car. An asleep car answers 408.

```yaml
action: tesla_telemetry.navigate
data:
  destination: "1 Tesla Road, Austin, TX"
```

The telemetry configuration expires on Tesla's side after roughly 30 days. The
integration checks daily and re-pushes automatically when the last sync is
more than 7 days old, so no manual upkeep is required.

## Troubleshooting

* **`synced: false` for a long time.** Tesla's flag lags reality. If the
  receiver log shows a vehicle connection, the car has the config.
* **TLS handshake failures in the receiver log.** Confirm the add-on is using
  the same hostname configured in the integration and that
  `/ssl/tesla-telemetry/ca.crt` existed before the last bootstrap/resync.
* **The receiver connects but no entities update.** Check that the add-on and
  integration use the same proxy secret. The add-on replaces both trusted
  `X-Tesla-*` headers after validating Tesla's client certificate.
* Enable debug logging with:
  ```yaml
  logger:
    logs:
      custom_components.tesla_telemetry: debug
  ```

## License

[MIT](LICENSE).

## Disclaimer

This integration is not affiliated with, endorsed by, or sponsored by Tesla,
Inc. "Tesla" is a trademark of Tesla, Inc.
