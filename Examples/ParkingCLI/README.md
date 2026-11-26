# Parking CLI

A Swift client for core's parking example (`examples/dto-parking`): the
`park` command asks a meters server for a session over `meters.start` v1.
Every DTO is generated from the JSON Schemas core exports from Lean.

| Path | What |
| --- | --- |
| `core/` | core's `examples/dto-parking/exported`, vendored at `core/CORE_REV`. CI checks it matches. |
| `Sources/ParkingContracts/Contracts.gen.swift` | From `./generate.sh` (`tribrach-swift gen`). Don't edit it. |
| `Sources/ParkClient` | `MetersClient`: checks each request against its schema before sending, and each answer before returning it |
| `Sources/park` | The command line |

```sh
swift run park --zone A1 --plate ABC123 --minutes 60 --server http://localhost:8080
```

## What the tests check

- **Decoders against Lean**: about 2,400 mutated messages from
  `core/verdicts`. Each generated decoder accepts exactly the ones Lean's
  schema accepts.
- **Round trips**: every message in `core/exchanges` decodes and writes back
  as the same JSON.
- **The client against the model**: for each v1 exchange core recorded, the
  client sends exactly the recorded request and reads the recorded answer.
  Requests the schema rejects never leave the client.

The client speaks v1 only. Core proves that a v2 server answers v1 clients
exactly as a v1 server would (`Meters.v2_serves_v1`), and tribrach-go's
`examples/parking-services` checks that its server does.
