# Weather provider and integration evidence

Reviewed 12 October 2026. This is research and local fixture verification, not a service activation or deployment receipt. No credentials were read or created, agreements accepted, paid APIs enabled, or authenticated weather requests made.

## Existing shared engine

Local Fonsters checkout `/Users/nathan/Documents/GitHub/Fonsters` was clean at `9eac44fdbb99e6b85980bd9b99d8c76a9816b5d9`. Its [handoff](/Users/nathan/Documents/GitHub/Fonsters/docs/backend/shared-weather-integration.md), [contract](/Users/nathan/Documents/GitHub/Fonsters/server/weather/README.md), and [implementation](/Users/nathan/Documents/GitHub/Fonsters/server/weather/service.js) still describe an offline integration candidate. Inspection of `sst.config.ts` and `aws/flags.mjs` found no weather route, durable weather store, provider adapter, or production account-session boundary. Existing preview authentication is not app-account authentication. No verified service URL can be supplied from this evidence.

`npm run test:weather` was rerun in that checkout: **22 passed, zero failures**. They use injected providers and `LocalWeatherStore`, not WeatherKit or a distributed database. The tests cover expiry/coverage, miss coalescing, quota accounting, refusal transactions, timeouts, fencing, backoff and bounds. This proves the fixture contract; it does not prove production storage, membership usage, auth, or deployment.

V2 is a JavaScript method contract, not a documented HTTP API:

```js
service.snapshot({ version: 2, latitude, longitude,
  datasets: ['current', 'hourly'] }, internalServerToken)
```

```text
version: 2
location: {latitude, longitude}   // originating provider request point
datasets.current:
  observedAt, expiresAt, providerExpiresAt
  condition: {code, temperatureC, daylight}
datasets.hourly:
  observedAt, expiresAt, providerExpiresAt
  hours: [{startAt, code, temperatureC, daylight, precipitationChance}]
expiresAt: minimum selected dataset expiry
source: apple | cache
stale: false
provenance: {provider: apple-weather, transformed: false}
attribution: {serviceName: Apple Weather, markURL, legalPageURL}
```

Times are epoch **milliseconds**. `observedAt` represents provider procurement/read time, not a station observation. Hourly has 24 consecutive UTC hours starting with the current hour; the provider can retain 26 to maintain rolling coverage. Probabilities are 0…1. Current and hourly have independent original expiry. Daily, historical hours, gusts, detailed precipitation, nowcasts, timezone and geocoding are absent. Do not migrate a daily-capable client to this without extending coverage. Internal server tokens must never be embedded in native apps; an authenticated transport and app-scoped account sessions remain prerequisites.

The prototype's two-hour/30 km reuse limit is its own policy, not Apple's approval or a rain accuracy guarantee. Reuse preserves timestamps. Its store must supply serializable transactions across replicas, conditional fencing, durable quota and idle physical TTL cleanup. Actual billing-cycle data and aggregate usage outside the engine are mandatory for strict v2. Errors include `weather_not_configured`, `weather_budget_exhausted`, `weather_backoff`, `weather_inflight`, and epoch-ms `retryAt` where supplied. Native fallback must not bypass shared quota refusal.

Split Flapp is available locally at `/Users/nathan/Documents/GitHub/onecolorapp`, revision `a25e1f33546ef1cf5441d1e86c9e75cc5b59f736`. It has untracked verification logs; they were preserved. [FlappSources.swift](/Users/nathan/Documents/GitHub/onecolorapp/OneColorApp/FlappSources.swift) directly requests `WeatherService.shared.weather(... including: .current)` and attribution. No shared-weather transport was found in those sources. Its [11 October verification record](/Users/nathan/Documents/GitHub/onecolorapp/app-store-audit/2026-10-11-reviewed-fixes/VERIFICATION.md) reports live WeatherKit and the Studio toolchain as unrun evidence. A tested native UI or protocol fixture is not a live service receipt.

## Apple WeatherKit

The included allowance is **500,000 calls/month per Developer Program membership**, shared across apps. Remaining usage was not inspected. Native WeatherKit requires macOS 13/iOS 16 and Xcode 14+, so its baseline API fits this project's macOS 15.6/iOS 18 targets. Minute precipitation is regional, not globally guaranteed. Raw forecast displays need the supplied Weather trademark and legal data-source link; transformed scenery needs modified-data attribution. [Apple WeatherKit](https://developer.apple.com/weatherkit/)

The current agreement places WeatherKit in **Attachment 8**, sections 1.5–1.6 (older prototype notes say Attachment 6). It prohibits bulk extraction and secondary/derived databases and permits only limited temporary performance caching unless documentation expressly permits more. It does not specify a blanket two-hour allowance or approve cross-app reuse. Keep native caches bounded and ephemeral; shared activation needs a review of actual retention and cross-app use. [Current Developer Program agreement](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)

## Maps import and explicit place selection

Google documents a Home and Work JSON object: `features`, `feature.geometry`, `geometry.coordinates` (latlng), `geometry.type` (`Point`), `feature.property`, `property.name`, and optional `property.address`. Fields may be omitted. Its currently rendered resource-group table does not establish which scope guarantees that exact object. Treat that mapping as unverified rather than inventing it. [Maps export schema](https://developers.google.com/data-portability/schema-reference/maps)

`https://www.googleapis.com/auth/dataportability.maps.aliased_places` is a **Restricted** scope; it exports labeled places. That listing alone does not prove guaranteed Home/Work contents. [Scope categories](https://developers.google.com/data-portability/user-guide/scopes)

Data Portability has separate consent and cannot mix scopes with Sign-in/userinfo scopes or `include_granted_scopes=true`. Native/desktop OAuth flows are supported. One-time export needs fresh consent for another export; exports may outlast access tokens. [OAuth setup and restrictions](https://developers.google.com/data-portability/user-guide/configure-oauth)

The Netherlands is supported; the US is not in the current supported-country list. Managed accounts, under-18 accounts, and Advanced Protection can be excluded. Eligibility depends on the Google account's associated country. Google Takeout is the documented alternative where supported by the receiving service. [User eligibility](https://support.google.com/accounts/answer/14452558)

API setup requires a Cloud project, billing enablement, and API activation. Restricted access also entails verification/security requirements and a clear in-context disclosure followed by affirmative consent. None was activated. A local file importer can parse a user-selected export, preview only Home/Work, validate coordinates, and let the user confirm browser-owned aliases without requiring Google Sign-in. Archive variants still need real consented sample verification. [API prerequisites](https://developers.google.com/data-portability/user-guide/setup), [data policy](https://developers.google.com/data-portability/policy)

Explicit map-link parsing is feasible without reading private account labels:

- Google: `/maps/search/?api=1&query=ADDRESS_OR_LAT,LON`, optionally `query_place_id`. General queries still require disambiguation. A map `center` is a viewport, not proof of a selected place. [Documented Google Maps URLs](https://developers.google.com/maps/documentation/urls/get-started)
- Apple unified URLs (macOS 15.4+/iOS 18.4+): `/place?coordinate=LAT,LON`, `address`, `name`, `place-id`; `/search?query=...` uses `center` only as search context. Short Apple Maps hosts ending in `maps.apple` expose the full URL through HTTP 301. Follow redirects only after explicit user action, with destination validation. [Apple unified Maps URLs](https://developer.apple.com/documentation/mapkit/unified-map-urls)

Implementation recommendation: support bounded, allowlisted full place/search URLs and manual addresses first. Preserve ordinary navigation. Never interpret undocumented `@LAT,LON` camera state as Home, silently inspect Maps DOM, or assume a signed-in account grants label access.

## Netherlands regional precipitation

KNMI `radar_forecast` **2.0** is HDF5, CC BY 4.0, with 25 steps (+0…+120 minutes), five-minute precipitation sums and 1 km cells. Convert a decoded five-minute **mm amount ×12** to mm/hour. The metadata projection is:

```text
+proj=stere +lat_0=90 +lon_0=0 +lat_ts=60
+a=6378137 +b=6356752 +x_0=0 +y_0=0 +units=km
```

The advertised bounding box is not a rectangular guarantee of valid radar coverage; the mask must be honored. [Dataset metadata](https://dataplatform.knmi.nl/dataset/radar-forecast-2-0)

The Open Data API lists files then issues download URLs. Its token belongs in the `Authorization` header. KNMI recommends Notification Service for new files and considers excessive discovery polling abuse. Registered limits are currently 1,000 requests/hour and 200/second; anonymous limits are shared. No token or authenticated sample was used here. [KNMI API access](https://developer.dataplatform.knmi.nl/open-data-api)

General KNMI HDF5 v3.8 declares these metadata fields, **not their actual radar_forecast values**: Geographic `geo_number_columns/rows`, `geo_pixel_size_x/y`, `geo_column_offset/row_offset`, `geo_pixel_def`, and projection `projection_proj4_params`; repeated Image `image_data` [rows,columns], `image_datetime_valid`, `image_geo_parameter`; Calibration `calibration_formulas` or table, `calibration_missing_data`, `calibration_out_of_image`. Read geometry, orientation, calibration and UTC valid timestamps from a real file. Example sentinel 255 is not a dataset constant. Do not execute a calibration expression as arbitrary code. [KNMI HDF5 specification, sections 5.5–5.6](https://cdn.knmi.nl/system/data_center_publications/files/000/072/301/original/hdftag38.pdf)

Actual dimensions, pixel origin/centre convention, group names, raw scaling, missing sentinel and per-step timestamp layout remain **unverified** without a licensed authenticated sample. A native sampler can be tested with explicit geometry and missing-value fixtures, but must not be presented as validated KNMI ingestion. The [KNMI repository](https://gitlab.com/KNMI-OSS/radar/datasets/-/blob/main/seamless/README.md) includes dated pilot prose for the separate blended product; that is not proof of current availability for its six-hour ensemble. Keep this evaluation scoped to the current two-hour dataset.

For the northern polar ellipsoidal projection, a source-derived formula is `e=sqrt(1-b²/a²)`, `t(phi)=tan(pi/4-phi/2)/((1-e*sin(phi))/(1+e*sin(phi)))^(e/2)`, `m_c=cos(phi_c)/sqrt(1-e²*sin²(phi_c))`, `rho=a*m_c*t(phi)/t(phi_c)`, `x=rho*sin(lambda)`, `y=-rho*cos(lambda)` with radians, `phi_c=60°`, zero central longitude, and final meters→km. This is an inference from [PROJ stereographic source](https://raw.githubusercontent.com/OSGeo/PROJ/master/src/projections/stere.cpp) and [tsfn](https://raw.githubusercontent.com/OSGeo/PROJ/master/src/tsfn.cpp). Compare known points against PROJ before enabling production sampling; reject unsupported CRS. [Projection parameters](https://proj.org/en/stable/operations/projections/stere.html)

Recommended activation: ingest one regional run once, decode/calibrate and publish bounded regional cells/tiles; sample locally to avoid sending every coordinate to KNMI. Cache by dataset/version/run/geometry with a much shorter freshness window than general weather. Carry issue time, interval, valid time, mask, attribution and expiry. Missing pixels are unknown, never dry. Old/gapped runs must disable dry-window claims. A deterministic grid has no ensemble confidence; label forecast uncertainty rather than fabricating a probability.

No Buienradar mobile/commercial integration or regional backend was activated. No compatible regional ingestion deployment/auth/credential receipt was found.

## Optional native provider keys

Tomorrow.io documents an `apikey` request header; do not use its alternative query-key syntax. Keys carry full privileges and need secure handling. User keys can stay device-local in Keychain, isolated from shared accounts/caches. Reject cross-host redirects so the header cannot escape. This is a feasible adapter candidate, not a verified account entitlement. [Authentication](https://docs.tomorrow.io/reference/api-authentication)

Forecast: `GET https://api.tomorrow.io/v4/weather/forecast?location=LAT,LON&units=metric`; optional `timesteps` selects `1h`/`1d`. JSON root is `timelines` and `location:{lat,lon,name,type}`; each hourly/daily entry is `{time,values}`. Hourly fields include `temperature`, `temperatureApparent`, `weatherCode`, `windSpeed`, `windGust`, `precipitationProbability`, `rainIntensity`, `snowIntensity`, `sleetIntensity`, `freezingRainIntensity`. Daily uses `temperatureMin/Max`, `weatherCodeMax`, `precipitationProbabilityAvg/Max`, `rainAccumulationSum`, `rainIntensityAvg`, `sunriseTime/sunsetTime`, `windGustMax`. Hourly is up to 120h and daily five days; next-hour minutely requires premium access. Forecast data is not a current observation. [Endpoint and OpenAPI schema](https://docs.tomorrow.io/reference/weather-forecast)

Metric temperatures are Celsius, winds m/s, intensity mm/hour, and probability **percent**, requiring division by 100 for a normalized 0…1 contract. Do not confuse intensity with accumulated amount. [Field units](https://docs.tomorrow.io/reference/data-layers-core)

Free plan limits currently are 500/day (00:00 UTC reset), 25/hour, 3/second. Respect quota/rate errors and bounded retries; no silent paid upgrades. Actual user plan permissions, caching terms and live schema require account-level verification before activation. [Free plan limits](https://support.tomorrow.io/hc/en-us/articles/20273728362644-Free-API-Plan-Rate-Limits)

## Compatibility and compute evidence

This Browser project's `project.pbxproj` currently declares objectVersion 77, Swift 6, macOS 15.6 and iOS 18. [ADR-0002](adr/0002-fast-forward-is-a-plain-split.md) explicitly preserves a standalone path on macOS 15.6 when macOS 26 FoundationModels is unavailable. Keep deployment targets and runtime fences; do not adopt newer SDK-only weather/geocoding APIs unconditionally. Split Flapp's Swift 5/objectVersion 56 settings belong to that app, not this one.

No verified Studio OS/Xcode version or reachable idle owned build worker was established by repository docs/scripts inspected here. Existing private idle article workers are feature architecture, not idle build-host receipts. Preserve local build tools and test compatibility on the actual older Studio when available; being online is insufficient for offloading.

## Remaining activation blockers

1. Shared service: real authenticated route, account scopes, durable transaction/TTL implementation, WeatherKit adapter/credentials, exact membership-cycle usage, coverage extensions, retention/disclosure review and deployment verification.
2. KNMI: existing authorized token/ingestion owner, real HDF5 calibration/geometry fixtures, known-point projection validation, fresh regional transport and actual service availability.
3. Google API import: eligibility, Cloud/billing/API approval, verified restricted-scope mapping and consent/security review. Manual and user-selected file imports need none of that activation.
4. BYO: explicit user-selected existing provider key, account plan permissions and a bounded live adapter test. Fixtures must remain visibly distinct from live data.

Skipped: live provider calls, deployments, account inventories and remote worker probes. Risk: fixture contracts and public metadata cannot establish production availability or actual older-Studio compatibility.
