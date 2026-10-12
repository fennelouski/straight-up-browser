# Weather next version

Implemented locally on 12 October 2026. This is a native implementation and an
integration candidate, not a deployed backend or a verified live-provider release.

## Working features

- Case-insensitive weather commands accept locations before/after `weather`,
  `rain home`, tomorrow modifiers, `when will rain stop?`, and `next dry window`.
  History and ordinary URLs/searches retain their existing paths. The web-search
  button submits the original query.
- Apple MapKit resolves addresses/postcodes to town, region, country and timezone.
  Multiple matching towns require a choice. Public postcode fixtures cover
  `80516` → Erie, Colorado, US, and `2725 DM` → Zoetermeer, Netherlands. Production
  geocoding never reads the fixture mapping.
- Browser-owned Home/Work and up to 20 named places can be edited, deleted and
  reset. They stay in the local browser profile. Explicit actions save a displayed
  place or a supported open Maps URL. Supported links include Apple place/search
  URLs and Google Maps API search URLs. Camera-only and shortened URLs need a
  manual address/full supported link. Pages and private Maps labels are not scraped.
- A user-selected Home/Work JSON export can be imported locally. Google sign-in
  and Data Portability API access are not assumed or activated.
- Each omnibar keeps its previous forecast while the next location loads. Loading,
  failures and ambiguity choices remain above the retained forecast. Generation
  checks and cancellation prevent obsolete responses from replacing it. Input
  focus stays outside the forecast transition. Newspaper and omnibars use one
  native request/cache owner.
- Opening or closing weather keeps the omnibar at its configured position. The
  floating panel expands downward from the same top edge, with its forecast
  height limited to the available screen space.
- Provider-tagged current/hourly/daily forecasts include gusts and precipitation
  amounts where available. Tomorrow uses actual daily/hourly data, not current
  values relabelled as future weather. Units and the resolved location's timezone
  apply to the UI; chart audio descriptions use that timezone too.
- Hourly dry windows use complete future forecast buckets and say "hourly
  estimate". They do not infer minute-level stopping times. Stale forecasts disable
  dry-window claims. Imported, fresh five-minute tiles can support finer estimates;
  missing values stay unknown.
- Transparent animation overlays, gravity/drag, wind, rain splashes/drainage and
  capped snow deposits remain. Collisions cover registered browser controls,
  not arbitrary webpage elements. Reduce Motion, zero animation duration and
  Low Power Mode remain supported.

## Caches, providers and credentials

Forecast requests and geocoding coalesce; typing is debounced 350 ms. Location
choices/geocoding are separate from provider requests. In-memory caches are bounded
to 20 entries each and have active expiry cleanup. Geocoding lasts 15 minutes;
Apple forecast reuse ends at the earliest provider expiry or one hour; Tomorrow.io
reuse lasts five minutes. Views can label an older forecast stale, then remove it
at the two-hour display-retention bound. These are conservative product bounds,
not an Apple-approved general caching entitlement. No permanent Apple weather
history or shared user-place database exists.

Native local safeguards reserve four attempts per Apple fetch, bounded at 100/day
and 1,000/month. Tomorrow reserves two calls for realtime + forecast, with free-plan
bounds of 500/day, 25/hour and 3/second. Counters are conservative local reservations,
not actual membership-wide remaining usage. HTTP quota refusals keep retry times;
cache hits remain usable. No automatic billable retry or fallback loop exists.
Apple outage fallback requires the explicit setting and configured native capability;
credentials/quota refusals do not trigger fallback.

Tomorrow.io uses official HTTPS endpoints with header-only `apikey` authentication.
Redirects, cookies and disk response caches are disabled. Native keys are masked,
validated, replaceable/removable and stored in a non-synchronizing device-only
Keychain item under the browser bundle identity. Keys never appear in URLs, logs,
fixtures or weather caches. Saving a key disables requests until the user explicitly
enables them after checking the existing plan. Validation uses the current place
and the same request/quota owner. Apple signing credentials are not paste-in keys.
There is no server-side credential storage or opt-in transmission of keys to a backend.

## Regional input contract

`KNMIRadarGrid` accepts an explicitly normalized regional JSON tile, at most
128×128 cells, with the documented KNMI polar stereographic projection, a centre
origin for cell (0,0), signed one-kilometre steps and row-major values. It requires
25 consecutive UTC steps at 300-second intervals, issue/expiry times, dataset
`radar_forecast`, version `2.0`, and an explicit fixture flag. Values are already
calibrated millimetres per five minutes; null is missing. Local sampling multiplies
amounts by 12 for mm/hour. Freshness is at most ten minutes. Dry-window calculations
exclude the horizon endpoint's following interval.

This validates the normalized format and mathematical sampler. It does **not**
claim a verified decoder for raw KNMI HDF5. Actual file calibration, orientation,
interval timestamp semantics, independent known-point PROJ comparison and a fresh
licensed ingestion transport remain prerequisites. No user coordinate is sent to
KNMI by this implementation. Until a feed is configured, hourly fallback is labelled.

## Configuration and remaining blockers

1. Apple live weather needs the existing signed WeatherKit capability and App
   Service access described in DEPLOYMENT.md. Ad-hoc development builds show a
   clear unavailable state; explicit UI fixtures remain usable.
2. Optional Tomorrow.io needs an existing account/key, its plan permissions and a
   bounded live check. No key was supplied or enabled during implementation.
3. Fonsters' shared v2 prototype passed its 22 fixture tests, but has no verified
   weather HTTP route, account-session boundary, durable store, provider adapter,
   reconciled membership quota or deployment. Browser validates its existing
   contract offline. Missing daily/past-hourly coverage and local rain accuracy
   must be resolved before activation. No internal server token is embedded.
4. KNMI needs an authorized ingestion owner/token, actual HDF5 sample metadata,
   projection/calibration validation and an authenticated fresh regional transport.
   No Buienradar commercial/mobile integration is enabled.
5. Google API import needs approved billing/API activation, eligibility, exact
   restricted-scope mapping and consent/verification review. Manual/file imports
   work independently.
6. The Mac Studio's actual older OS/Xcode and a verified idle remote build host
   were unavailable. Deployment targets remain macOS 15.6 / iOS 18; no target or
   project format was raised.

Primary documentation and prototype receipts are in
[weather-provider-research.md](weather-provider-research.md).

## Verification

- Passed: 27 weather tests in three suites through
  `./scripts/test-weather-kernel.sh`. This copies the actual model/coordinator/
  adapter/store implementations into a temporary Swift package and runs the
  existing test files; only the fixture resource-bundle lookup changes. It installs
  no dependency and makes no provider calls. Fixtures cover parsing, aliases,
  geocoding/deduplication, ambiguity, cache expiry, quota/fallback, rapid edits,
  cancellation/reopening, offline recovery, permission denial, credentials,
  contracts, grid bounds/missing data/unit conversions and animation physics.
- Passed earlier: 26 app-hosted weather tests before the final UI/retention additions.
- Final app-hosted rerun blocked: XCTest reported "The test runner hung before
  establishing connection" and timed out initiating its daemon control session.
- UI automation blocked: "Timed out while enabling automation mode"; the UI
  target compiled, but its three selected tests did not execute.
- Release build and manual screenshot results are recorded after the final checks
  below. Screenshots are visibly marked preview data, not live forecasts.

No deployment, credential creation, paid usage, new agreement acceptance, Google
OAuth activation, live nowcast ingestion or signed release packaging occurred.

Final checks: both macOS arm64 and iOS Simulator Release builds passed with warnings
as errors. The development launcher passed. Manual fixture checks passed for both
postcodes, resolved countries/timezones, tomorrow's daily values and hourly graph,
missing Home aliases, Escape dismissal and reopening. Screenshots:
[Erie](verification/weather/erie-fixture.png),
[Zoetermeer](verification/weather/zoetermeer-fixture.png),
[tomorrow](verification/weather/tomorrow-fixture.png).

No code assertion failure remains in the 27-test kernel run. The failed XCTest
host/automation sessions remain infrastructure blockers; they do not prove the
full app-hosted or UI suite passed. Real provider credentials, real radar ingestion,
actual VoiceOver speech and the older Studio runtime were not verified.

The stable-omnibar follow-up passed the macOS development build and UI
build-for-testing with warnings as errors. Position assertions cover weather
opening/closing and the floating panel. Manual before/after checks confirmed the
field stays anchored within both presentations; automated execution remains
blocked by the XCTest daemon described above. Screenshots:
[in-window before](verification/weather/stable-omnibar-before.png),
[in-window after](verification/weather/stable-omnibar-after.png),
[floating before](verification/weather/stable-global-before.png),
[floating after](verification/weather/stable-global-after.png).
