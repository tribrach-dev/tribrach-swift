#!/bin/sh
# Regenerate Sources/ParkingContracts/Contracts.gen.swift from core/schemas.
# With -n, change nothing and fail if the file is out of date.
set -e
cd "$(dirname "$0")"
s=core/schemas
swift run --package-path ../.. tribrach-swift gen "$@" -o Sources/ParkingContracts/Contracts.gen.swift \
  AuthorizeRequest=$s/payments.authorize.request.json \
  AuthorizeResponse=$s/payments.authorize.response.json \
  StartRequest=$s/meters.start.v1.request.json \
  StartResponse=$s/meters.start.v1.response.json \
  StartRequestV2=$s/meters.start.v2.request.json \
  StartResponseV2=$s/meters.start.v2.response.json
