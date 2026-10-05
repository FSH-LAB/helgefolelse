#!/usr/bin/env bash
set -euo pipefail
url="${1:?usage: smoke-test.sh <base-url>}"
: "${SHA:?}"
curl_opts=(--fail --show-error --silent --retry 10 --retry-delay 2 --retry-all-errors)

health="$(curl "${curl_opts[@]}" "$url/api/health")"
if ! jq -e --arg sha "$SHA" '.status == "ok" and .commit == $sha' <<< "$health" > /dev/null; then
  echo "::error::$url/api/health did not report commit $SHA" >&2
  echo "$health" >&2
  exit 1
fi

page="$(curl "${curl_opts[@]}" "$url/")"
if ! grep -q '<title>helgefølelse</title>' <<< "$page"; then
  echo "::error::$url/ did not render the home page" >&2
  exit 1
fi
