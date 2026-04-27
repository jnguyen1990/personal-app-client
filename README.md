# personal_app_client

Shared HTTP client for inter-app communication across Joe's personal apps
(`base`, `fitness`, `budgeter`).

## Why this exists

The three apps each had a near-identical `Net::HTTP` wrapper that:

- silently returned `[]` on non-2xx responses
- happily called `https://<app>.joenguyen.ca` URLs that Cloudflare Access
  intercepts with a 302 challenge

Result: when the public Cloudflare-fronted URL ended up in a `Setting` row,
inter-app sync broke without a single error log. This gem replaces those
wrappers with one that:

- raises on non-2xx (callers decide whether to swallow)
- refuses to start in production with a `*.joenguyen.ca` URL
- sends a shared-secret header so apps can authenticate each other
- retries once on transient network errors

## Usage

```ruby
require "personal_app_client"

client = PersonalAppClient::Client.new(
  base_url: Setting.get("fitness_app_url"), # e.g. http://fitness.tail5ece07.ts.net:3002
  secret:   ENV["INTER_APP_SECRET"],
  env:      Rails.env,
  logger:   Rails.logger
)

client.get("/api/planned-sessions", start_date: "2026-04-27", end_date: "2026-04-27")
client.post("/api/body-metrics", { recorded_at: Time.now, sleep_hours: 7.5 })
```

### Inbound auth (Rails)

```ruby
require "personal_app_client/rails/inter_app_auth"

class Api::FitnessSyncController < ApplicationController
  include PersonalAppClient::Rails::InterAppAuth
  # ...
end
```

The concern reads `ENV["INTER_APP_SECRET"]`, returns 503 if unset, and 401
if the request's `X-App-Auth` header doesn't match.

## Errors

- `ConfigurationError` — bad `base_url`, missing host, or production using a
  guarded public domain. Raised at construction.
- `ResponseError` — non-2xx response. Carries `status`, `body`, `url`.
  3xx responses to `cloudflareaccess.com` get a hint in the message.
- `ConnectionError` — connection refused / reset / unreachable after one
  retry.
- `TimeoutError` — read timeout exceeded.

## Local dev

```sh
bundle install
bundle exec rspec
```
