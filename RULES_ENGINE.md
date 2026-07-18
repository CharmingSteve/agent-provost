# Agent Provost — Dynamic Rules Engine

This document describes the hot-reloadable, JSON-driven risk rule system added to Agent Provost.  It is aimed at **SRE / DevOps** engineers who operate the proxy and at **developers** who extend it with new rules.

---

## Overview

The circuit-breaker logic has been extracted from `default.conf` into two Lua modules and an external JSON configuration file:

| Component | Path | Purpose |
|---|---|---|
| Rules config | `rules.json` | Declare, enable/disable, and tune rules |
| Rule engine | `lua/rules_engine.lua` | Pure evaluation function (no I/O) |
| Rule loader | `lua/rule_loader.lua` | Background timer that hot-reloads `rules.json` |
| Shared dict | `lua_shared_dict rules 1m` | In-memory store shared across all workers |

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  OpenResty worker                                                │
│                                                                  │
│  init_worker_by_lua_block                                        │
│    └─► rule_loader.lua ──── reads rules.json ──► lua_shared_dict │
│              │                                          ▲        │
│              └─► ngx.timer.at(10, reload_rules) ───────┘        │
│                                                                  │
│  access_by_lua_block (per request, zero disk I/O)                │
│    └─► rules_engine.check_request(parsed, rules)                 │
│          ▲                                                       │
│          └─── ngx.shared.rules:get("rules") ◄── lua_shared_dict │
└──────────────────────────────────────────────────────────────────┘
```

### Key properties

- **No per-request disk I/O.** Every access to the rule set goes through `ngx.shared.rules` (pure memory lookup).
- **Hot reload without nginx reload or HUP.** The background timer polls `rules.json` every 10 seconds; when the file's `mtime` changes, the new JSON is parsed and atomically written to the shared dict.
- **Safe against partial writes.** The loader validates JSON with `cjson.decode` before touching the shared dict. A malformed file leaves the previous rule set intact and logs an `[ERR]` line.
- **Multi-worker safe.** Each worker independently maintains a local `last_mtime` variable and writes to the shared dict. Because all workers write the same validated content, there is no race condition.

---

## `rules.json` Structure

Each top-level key names a rule. Every rule object **must** contain:

```jsonc
{
  "<rule_name>": {
    "enabled": true,          // boolean: true = enforce, false = skip
    "description": "...",     // human-readable note (optional but recommended)
    "params": {               // rule-specific configuration
      // ...
    }
  }
}
```

### Bundled rules

#### `max_trade_size`

Blocks requests whose share quantity exceeds `params.limit`.

Accepted quantity fields:

- `quantity`
- `qty`
- `order_quantity`

Also evaluates notional orders (`notional`) to prevent quantity-limit bypass.

- If `limit_price` is present and valid, estimated shares are calculated as `notional / limit_price`.
- If `limit_price` is missing or invalid for a notional order, the request is blocked (fail-safe).

```json
"max_trade_size": {
  "enabled": true,
  "description": "Block trades whose quantity exceeds the maximum allowed limit.",
  "params": {
    "limit": 100
  }
}
```

| Param | Type | Default | Description |
|---|---|---|---|
| `limit` | number | 100 | Maximum allowed trade quantity (inclusive boundary: `qty > limit` blocks) |

#### `max_trade_notional`

Blocks requests whose estimated dollar value exceeds `params.limit`.

Evaluation order:

- If `notional` is provided and positive, that value is used.
- Otherwise, when both quantity and `limit_price` are present and valid, estimated value is `qty * limit_price`.
- Notional orders without valid `limit_price` are blocked (fail-safe).

```json
"max_trade_notional": {
  "enabled": true,
  "description": "Block trades whose dollar notional value exceeds the configured limit.",
  "params": {
    "limit": 50000
  }
}
```

| Param | Type | Default | Description |
|---|---|---|---|
| `limit` | number | 50000 | Maximum allowed per-order notional value |

#### `cumulative_trade_notional`

Blocks requests when rolling cumulative exposure for a `(user, machine, symbol)` key would exceed `params.limit` within `params.window_seconds`.

This rule uses the `provost_ctx` shared dictionary to maintain per-identity rolling state. If risk state cannot be updated safely, requests are blocked to avoid untracked exposure.

```json
"cumulative_trade_notional": {
  "enabled": true,
  "description": "Block cumulative dollar exposure across multiple orders within a short rolling window.",
  "params": {
    "limit": 50000,
    "window_seconds": 300
  }
}
```

| Param | Type | Default | Description |
|---|---|---|---|
| `limit` | number | 50000 | Maximum cumulative notional within the active window |
| `window_seconds` | number | 300 | Rolling window length in seconds |

#### `symbol_order_cooldown`

Blocks repeat orders for the same symbol within a rolling cooldown window for a `(user, machine, symbol)` key.

```json
"symbol_order_cooldown": {
  "enabled": true,
  "description": "Block repeat orders for the same symbol within a rolling time window.",
  "params": {
    "window_seconds": 300
  }
}
```

| Param | Type | Default | Description |
|---|---|---|---|
| `window_seconds` | number | 300 | Cooldown duration for repeat orders on the same symbol |

#### `blocked_tickers`

Blocks any request whose `ticker` or equivalent symbol field matches a symbol in `params.tickers`.

```json
"blocked_tickers": {
  "enabled": true,
  "description": "Block trades on restricted ticker symbols.",
  "params": {
    "tickers": ["GME", "AMC", "BBBY"]
  }
}
```
| Param | Type | Description |
|---|---|---|
| `tickers` | string[] | List of exact ticker symbols to reject |

#### `restricted_ticker_tool_rules`

Blocks requests that use a specific trade tool and a restricted ticker symbol, even when the symbol is provided via different field names.

```json
"restricted_ticker_tool_rules": {
  "enabled": true,
  "description": "Block restricted symbols when they are used by specific trade tools, regardless of argument field naming.",
  "params": {
    "tools": ["place_stock_order", "place_option_order", "place_crypto_order"],
    "tickers": ["GME", "AMC", "BBBY"]
  }
}
```

| Param | Type | Description |
|---|---|---|
| `tools` | string[] | Tool names whose requests should be checked against restricted symbols |
| `tickers` | string[] | Restricted ticker symbol list |

#### `trading_window`

*(Disabled by default)* Placeholder for a time-of-day restriction. When enabled, only requests that arrive between `start_hour` and `end_hour` (UTC, 24-hour) are allowed.

```json
"trading_window": {
  "enabled": false,
  "description": "Restrict automated trading to allowed UTC hours.",
  "params": {
    "start_hour": 13,
    "end_hour": 21
  }
}
```

---

## Hot-Reload Mechanism

1. `init_worker_by_lua_block` in `default.conf` calls `require("rule_loader")` once per worker at startup.
2. `rule_loader.lua` immediately reads and validates `rules.json`, writing the result to `ngx.shared.rules`.
3. A recurring `ngx.timer.at(10, reload_rules)` callback wakes every 10 seconds, compares the file's `mtime` to the last-seen value, and reloads only when the file has changed.
4. If parsing fails (invalid JSON, empty file, array instead of object), the existing rules remain active and an error is written to the nginx error log.

### Demonstrating a live rule change (no restart)

```bash
# Start the stack
docker compose --env-file .env.versions up -d

# Check that a large trade is blocked
curl -s -X POST http://localhost:8088/mcp \
  -H "Content-Type: application/json" \
  -d '{"params":{"arguments":{"quantity":500}}}' | jq .
# → {"error":"PROVOST_INTERVENTION: Risk Limit Exceeded..."}

# Lower the limit to 10 by editing rules.json on the host
perl -0777 -i -pe 's/"limit": 100/"limit": 10/' rules.json

# Wait up to 10 seconds for the reload timer to fire, then retry
sleep 12
curl -s -X POST http://localhost:8088/mcp \
  -H "Content-Type: application/json" \
  -d '{"params":{"arguments":{"quantity":50}}}' | jq .
# → {"error":"PROVOST_INTERVENTION: Risk Limit Exceeded..."}
# A trade of 50 is now blocked because the limit is 10.

# Restore
perl -0777 -i -pe 's/"limit": 10/"limit": 100/' rules.json
```

---

## Adding a New Rule

1. **Edit `rules.json`** — add a new key:

   ```json
   "max_daily_trades": {
     "enabled": true,
     "description": "Block if the daily trade count exceeds a cap.",
     "params": {
       "max_count": 20
     }
   }
   ```

2. **Extend `lua/rules_engine.lua`** — add a new block inside `check_request`:

   ```lua
   local daily_rule = rules.max_daily_trades
   if type(daily_rule) == "table" and daily_rule.enabled == true then
       -- ... implement your logic using args / ngx.shared etc.
   end
   ```

3. **Add unit tests** in `tests/lua/rules_engine_spec.lua` following the existing pattern.

4. **Save `rules.json`** — OpenResty picks up the change within 10 seconds; no reload required.

---

## Volume Mounts

`docker-compose.yml` mounts the following **read-only** paths into the `agent-provost` container:

| Host path | Container path | Description |
|---|---|---|
| `./default.conf` | `/usr/local/openresty/nginx/conf/nginx.conf` | Main nginx config |
| `./lua/` | `/etc/nginx/lua/` | Lua modules directory |
| `./rules.json` | `/etc/rules.json` | Live rule configuration |

To update rules in a running container, edit `rules.json` on the host.  The bind-mount means the container sees the change immediately; the reload timer will pick it up within its polling interval.

---

## Error Handling

| Failure | Behaviour |
|---|---|
| `rules.json` missing at startup | Error logged; shared dict left empty (all rules skip = fail-open) |
| `rules.json` unreadable | Error logged; previous rules remain active |
| Invalid JSON | Error logged; previous rules remain active |
| JSON array instead of object | Error logged; previous rules remain active |
| Shared dict full | Error logged; write fails but previous rules remain active |
| Timer scheduling failure | Error logged; no further reloads (restart required) |

All errors appear in the nginx error log at `ERR` level:

```
[rule_loader] JSON parse error in '/etc/rules.json': ...
[rule_loader] rules reloaded from /etc/rules.json
```

---

## Performance Notes

- `ngx.shared.rules:get("rules")` is an O(1) memory lookup using the built-in OpenResty LRU shared dict.
- `cjson.decode` is called once per request to deserialise the cached JSON string into a Lua table.  For very high throughput, consider caching the decoded table in `ngx.ctx` or using a worker-local variable protected by a version counter — but this is rarely necessary in practice.
- The background timer uses one Lua coroutine per worker and does not block the event loop.

---

## Operational Checklist

- [ ] Confirm `rules.json` is mounted read-only (`:ro`) into the container.
- [ ] Verify the initial load succeeds: `docker logs agent-provost | grep rule_loader`.
- [ ] Validate your edited `rules.json` with `python3 -m json.tool rules.json` before deploying.
- [ ] Monitor Fluent Bit stream output (or recent S3 objects under `agent-provost/logs/`) for `[rule_loader]` entries after any rule change.
- [ ] If reload is urgent, you can force an immediate reload by touching the file (`touch rules.json`) to bump its mtime without changing its content.
