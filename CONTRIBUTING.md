# Contributing

Issues and pull requests are welcome.

## Development

```sh
swift test        # unit tests (parsers, HTTP parsing, version logic)
./build.sh        # build build/GetMyIP.app
open build/GetMyIP.app
log stream --level info --predicate 'subsystem == "com.akominch.GetMyIP"'
```

Before you open a PR:
- `swift test` is green and `./build.sh` succeeds; CI checks both;
- new behavior comes with tests where it can be tested without the network, e.g. a fixture for a new service's response;
- the app stays lightweight: no new third-party dependencies, no polling where a system event exists.

## Adding an IP service

1. Add an entry to `IPServices.all` in `Sources/GetMyIP/IPServices.swift`. Most JSON APIs need only `jsonService(id:title:url:ip:code:name:)`.
2. Add a real response sample for it to `testEveryServiceParsesItsRealResponseShape` in `Tests/GetMyIPTests/GetMyIPTests.swift`.
3. Use only services that work without an API key and return a 2-letter ISO country code.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): `feat: …`, `fix: …`, `docs: …`, `ci: …`.
