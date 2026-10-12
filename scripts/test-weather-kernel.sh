#!/bin/bash
# Run the actual weather models/tests without the macOS app-host/automation daemon.
set -euo pipefail
cd "$(dirname "$0")/.."
WEATHER_TEST_ROOT="$(mktemp -d /tmp/browser-weather-kernel.XXXXXX)"
trap 'rm -rf "$WEATHER_TEST_ROOT"' EXIT
python3 - "$WEATHER_TEST_ROOT" <<'PY'
from pathlib import Path
import json, re, sys
root = Path(sys.argv[1])
source = root / 'Sources' / 'Browser'
tests = root / 'Tests' / 'BrowserTests'
source.mkdir(parents=True); tests.mkdir(parents=True)
boundaries = {
    'WeatherPlaces.swift': 'struct WeatherPlacesEditor: View',
    'OmnibarWeather.swift': 'struct OmnibarWeatherSurfaces: PreferenceKey',
    'TomorrowWeatherAdapter.swift': 'struct WeatherProviderSettings: View',
    'BrowserRainForecast.swift': 'struct WeatherRegionalFeedSettings: View',
    'NewspaperWeather.swift': 'struct NewspaperWeatherMasthead: View',
}
for filename in [*boundaries, 'BrowserWeatherService.swift', 'SharedWeatherContract.swift', 'OmnibarWeatherScene.swift']:
    text = (Path('Straight Up Browser') / filename).read_text()
    if filename == 'OmnibarWeatherScene.swift':
        marker = 'nonisolated struct OmnibarWeatherParticle'
        assert text.count(marker) == 1, 'Particle extraction boundary changed'
        text = 'import Foundation\n' + marker + text.split(marker, 1)[1]
    elif filename in boundaries:
        marker = boundaries[filename]
        assert text.count(marker) == 1, f'{filename}: extraction boundary changed'
        text = text.split(marker, 1)[0]
    (source / filename).write_text(text)
# Copy the real preference constants rather than changing their test semantics.
preferences = Path('Straight Up Browser/Newspaper.swift').read_text()
keys = ['showWeather', 'weatherCity', 'weatherCurrentLocation', 'weatherTemperatureUnit']
constants = []
for key in keys:
    matches = re.findall(r'^[ \t]*static let ' + key + r' = "[^"]+"', preferences, re.M)
    assert len(matches) == 1, f'Missing/ambiguous real preference: {key}'
    constants.append(matches[0])
(source / 'WeatherPreferences.swift').write_text('enum NewspaperPreferences { enum Key {\n' + '\n'.join(constants) + '\n} }\n')
fixture = Path('Straight Up Browser/WeatherPreviewFixtures.json').read_text()
assert len(json.loads(fixture)['80516']) == 1, 'Missing postal fixture'
(tests / 'WeatherPreviewFixtures.json').write_text(fixture)
for filename in ['OmnibarWeatherTests.swift', 'WeatherServiceTests.swift', 'WeatherContractTests.swift']:
    text = (Path('Straight Up BrowserTests') / filename).read_text()
    # SwiftPM's test resource bundle is the only harness-specific substitution.
    text = text.replace('Bundle.main.url(forResource: "WeatherPreviewFixtures"', 'Bundle.module.url(forResource: "WeatherPreviewFixtures"')
    (tests / filename).write_text(text)
(root / 'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "BrowserWeatherKernel", platforms: [.macOS("15.6")], targets: [
    .target(name: "Browser", swiftSettings: [.defaultIsolation(MainActor.self)]),
    .testTarget(name: "BrowserTests", dependencies: ["Browser"], resources: [.copy("WeatherPreviewFixtures.json")], swiftSettings: [.defaultIsolation(MainActor.self)])
])
''')
PY
swift test --package-path "$WEATHER_TEST_ROOT" --scratch-path /tmp/browser-weather-kernel-build
