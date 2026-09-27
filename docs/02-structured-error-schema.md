# The Structured Error Schema

> **Principle 2 — Your Error Is an Agent's Next Step.** For an AI agent, an error response is not a debugging message. It is the agent's decision tree.

| File | What it is |
|---|---|
| [`schemas/error-schema/before.openapi.yaml`](../schemas/error-schema/before.openapi.yaml) | Seat assignment API whose errors are `text/plain`: "Something went wrong. Please try again." |
| [`schemas/error-schema/after.openapi.yaml`](../schemas/error-schema/after.openapi.yaml) | The same API with one machine-readable `Error` schema on every 4xx and 5xx response. |
| [`governance/agent-ready.spectral.yaml`](../governance/agent-ready.spectral.yaml) | The lint rules that reject the *before* file and accept the *after* file. |

The two schema files differ **only** in error handling. Status enums, idempotency, and trace headers are identical in both, so the diff isolates the error design.

---

## 1. The story

Monday morning. Brittany's agent tries to confirm her seat assignment on the booking it created over the weekend. It gets back:

```http
HTTP/1.1 500 Internal Server Error
Content-Type: text/plain

Something went wrong. Please try again.
```

No error code. No retry guidance. No indication of whether the failure is transient or terminal. The message literally says *try again*, so the agent does. Six times, which is its retry policy. Every attempt gets the same sentence. After the sixth, it gives up and (because the itinerary is already in its state) marks the booking as confirmed anyway.

Brittany ends up at the counter at 5:45 AM with two boarding passes and no confirmed seat.

A human developer who sees that message groans, opens the network inspector, looks at the status code, maybe files a ticket. They figure it out. An agent has literally nothing to work with.

## 2. The principle

Error design is usually an afterthought: build the happy path, then add handling "around the edges." For an agent consumer, errors deserve the same contract rigor as success responses, because every error is a branch point. The agent needs to answer three questions from the response alone:

1. **What happened?** — so it can match on it.
2. **Should I try the same thing again?** — and if so, **when?**
3. **If not, what should I do instead?**

The talk's error schema answers those with five fields:

```json
{
  "error_code": "SEAT_UNAVAILABLE",
  "message": "The selected seat is no longer available.",
  "retryable": true,
  "retry_after": 30,
  "remediation": "Query /flights?origin=ORD&dest=ATL&flexible=true"
}
```

| Field | Rule from the talk |
|---|---|
| `error_code` | Machine-readable, consistent, stable. A string like `SEAT_UNAVAILABLE`, not a number. Something the agent can match against. |
| `message` | Human-readable. This is what surfaces to a user or a log. Write it clearly. |
| `retryable` | Boolean. **The single most important field in the schema.** True: the agent may try again. False: escalate immediately and stop burning your rate limit. |
| `retry_after` | If retryable and you know a reasonable wait, include it, especially on 429s. Agents will hammer your rate limit if you do not tell them to wait. |
| `remediation` | Optional but powerful. What to do next. The agent can extract it and act on it. |

This repo keeps those five and adapts the design in a few places, described in section 4.

## 3. The before state

Open [`before.openapi.yaml`](../schemas/error-schema/before.openapi.yaml). Every error response points to one of two shared definitions:

```yaml
  responses:
    GenericError:
      description: Error.
      content:
        text/plain:
          schema: { type: string }
          example: Something went wrong. Please try again.
```

and it is used for 400, 409, 429, 500, and 503 alike:

```yaml
        '400': { $ref: '#/components/responses/GenericError' }
        '404': { $ref: '#/components/responses/NotFound' }
        '409': { $ref: '#/components/responses/GenericError' }
        '429': { $ref: '#/components/responses/GenericError' }
        '500': { $ref: '#/components/responses/GenericError' }
        '503': { $ref: '#/components/responses/GenericError' }
```

What goes wrong for an agent:

- **The status code is the only machine-readable signal**, and it is too coarse. A `409` could mean "the seat was sold" (pick another) or "the booking is still pending" (wait and retry). Those need opposite actions.
- **`text/plain` has no structure to parse.** The only way to extract meaning is to string-match on prose, which breaks the first time someone fixes a typo or localizes the message.
- **There is no `Retry-After` on 429 or 503.** The agent falls back to its own backoff, which is either too aggressive (hammering a rate limit) or too slow (missing a rebooking window).
- **"Please try again" is advice, and it is wrong half the time.** The agent follows it literally.
- **The operation description says "please try again"** too, so even the prose layer an agent reads reinforces the loop.

### What governance says about the before state

```text
$ spectral lint -r governance/agent-ready.spectral.yaml schemas/error-schema/before.openapi.yaml

 221:15  error  agent-error-must-be-json       Error responses must use application/json (or application/problem+json), not freeform text.  components.responses.NotFound.content
 227:15  error  agent-retry-after-on-throttle  429/503 responses must declare a Retry-After response header.                                components.responses.GenericError.headers
 231:15  error  agent-error-must-be-json       Error responses must use application/json (or application/problem+json), not freeform text.  components.responses.GenericError.content

✖ 3 problems (3 errors, 0 warnings, 0 infos, 0 hints)
```

## 4. The after state

Open [`after.openapi.yaml`](../schemas/error-schema/after.openapi.yaml).

### 4.1 One error shape for the whole API

```yaml
    Error:
      type: object
      description: |
        The single error shape for every 4xx and 5xx response in this API.
        All fields are always present; fields with nothing to say are null or empty.
      required: [error_code, message, retryable, retry_after, remediation, details, correlation_id, request_id]
      properties:
        error_code: { $ref: '#/components/schemas/ErrorCode' }
        message:
          type: string
          description: Human-readable explanation suitable for logs and for the traveler. Not for matching.
        retryable:
          type: boolean
          description: |
            True if repeating the identical request (same `Idempotency-Key`) may succeed.
            False means stop: retrying will fail the same way and only consumes rate limit.
        retry_after:
          type: [integer, 'null']
          minimum: 0
          description: Seconds to wait before retrying. Null when `retryable` is false.
        remediation:
          type: [string, 'null']
          description: What the caller should do next, in one sentence. Null when there is nothing to suggest.
        next_action:
          description: Optional machine-actionable version of `remediation`.
          $ref: '#/components/schemas/NextAction'
        details:
          type: array
          description: Field-level problems. Empty unless `error_code` is `VALIDATION_FAILED`.
          items: { $ref: '#/components/schemas/ErrorDetail' }
        correlation_id: { type: string, format: uuid }
        request_id:     { type: string, format: uuid }
```

Every 4xx/5xx response in the file references this one schema. An agent writes one error handler, not one per endpoint.

### 4.2 Adaptations beyond the slide

| Change | Why |
|---|---|
| **All fields `required`; `retry_after` and `remediation` nullable** | Principle 1's explicit-nullability rule applied to errors. The agent never has to ask whether a missing `retry_after` means "no wait" or "unknown." `null` means "not applicable," and the description says when. |
| **`correlation_id` and `request_id` in the body** | Principle 4. Many agent frameworks hand the tool only the response *body*. Putting the IDs in the body (as well as in `X-Correlation-ID` / `X-Request-ID` headers) means the agent can log them and a human can quote them to support. |
| **`next_action` (`method` + `href`)** | `remediation` is prose, good for humans and LLM-based agents. `next_action` is the same advice in a form a deterministic agent can execute without parsing a sentence. Optional, so providers can add it gradually. |
| **`details[]`** | Validation errors need to say *which* field is wrong. Always present, empty when not applicable. |
| **`Retry-After` header mirrors `retry_after`** | HTTP-level middleware (gateways, SDK retry handlers) reads the header; the agent reads the body. The description requires them to match. |
| **`error_code` is an `x-extensible-enum`** | See 4.4. |

### 4.3 `retryable` describes the occurrence, not the code

The talk uses `SEAT_UNAVAILABLE` twice, with different answers:

- During irregular operations (slide 7), the seat is unavailable because inventory is being reloaded: `retryable: true`, `retry_after: 30`, remediation "query flexible flights."
- In the Monday re-run (slide 12), the seat Brittany chose was sold: `retryable: false`, and the agent immediately offers alternatives.

Both are correct. **`retryable` is a property of this specific failure, decided by the server at the time it happens.** The *after* file shows both as named examples on the `409`:

```yaml
                seatUnavailableIrrops:
                  summary: IRROPS — inventory reloading, retry shortly (slide 7)
                  value:
                    error_code: SEAT_UNAVAILABLE
                    message: The selected seat is no longer available.
                    retryable: true
                    retry_after: 30
                    remediation: Query /flights?origin=ORD&dest=ATL&flexible=true for available alternatives.
                    next_action: { method: GET, href: /flights?origin=ORD&dest=ATL&flexible=true }
                    ...
                seatSold:
                  summary: Seat sold to someone else — do not retry (slide 12)
                  value:
                    error_code: SEAT_UNAVAILABLE
                    message: Seat 12C has been assigned to another passenger.
                    retryable: false
                    retry_after: null
                    remediation: Choose an AVAILABLE seat from GET /bookings/BK-99182/seat-map and call assignSeat with a new Idempotency-Key.
                    next_action: { method: GET, href: /bookings/BK-99182/seat-map }
                    ...
```

This is also why a consumer must never hard-code "code X is always retryable." Read the field.

The third `409` example ties back to Principle 1: `BOOKING_NOT_CONFIRMED` (`retryable: true`, `retry_after: 5`, remediation "poll until `CONFIRMED`"). Had this existed on the original Monday, the agent would have waited for the booking instead of looping.

### 4.4 Error codes: stable, matchable, and extensible

```yaml
    ErrorCode:
      type: string
      description: |
        Stable, machine-readable error identifier. Match on this, never on `message`.
        Codes are never renamed, removed, or reused. New codes may be added in a minor
        version, which is why this list is an `x-extensible-enum` rather than a closed
        `enum`: a consumer that receives a code it does not recognize must fall back to
        `retryable`, `retry_after`, and `remediation`, which are always present.
        - `VALIDATION_FAILED` — the request is malformed; see `details`.
        - `BOOKING_NOT_FOUND` — ...
        ...
      x-extensible-enum:
        - VALIDATION_FAILED
        - BOOKING_NOT_FOUND
        - BOOKING_NOT_CONFIRMED
        - SEAT_UNAVAILABLE
        - RATE_LIMITED
        - INTERNAL_ERROR
        - SERVICE_UNAVAILABLE
```

This is a deliberate contrast with status fields. A **status** enum is closed because the agent must handle every lifecycle state, and a new one is a breaking change ([01 — The Status Enum Pattern](01-status-enum-pattern.md)). An **error code** list grows over the life of an API, and the schema is designed so that an unknown code is still actionable: `retryable` tells the agent what to do even when `error_code` is new to it. `x-extensible-enum` (a convention from the Zalando RESTful API guidelines) documents the known values without making a new one a deserialization failure in generated clients, and `oasdiff` does not flag additions to it as breaking. We checked: adding `PAYMENT_DECLINED` to this list passes `scripts/breaking-check.sh`.

Every code is documented with its meaning in the description, so the agent and the tool manifest derived from the spec both carry the catalog.

### 4.5 Every error status gets the right headers and an example

- `429`, `500`, and `503` declare `Retry-After` and have concrete examples with `retryable: true`.
- `500 INTERNAL_ERROR` is marked retryable **because** the endpoint is idempotent (see [03 — The Idempotency-Key Header](03-idempotency-key-header.md)). Without idempotency, "retry a 500 on a write" is unsafe advice. The two principles depend on each other.
- `400` shows `details[]` in use.
- `404` is explicitly not retryable, with a remediation that points at the real mistake.

### 4.6 The description tells the agent how to use the errors

```yaml
      description: |
        ...
        On failure, read `error_code` and `retryable` — never parse `message`:
        - `retryable: true` → wait `retry_after` seconds, then repeat the identical
          request with the same `Idempotency-Key`.
        - `retryable: false` → do not repeat the request. Follow `remediation`
          (for `SEAT_UNAVAILABLE`, choose another seat from `getSeatMap`), or escalate
          to the traveler with `message`.
```

That paragraph is the decision tree, written where the agent reads it.

### 4.7 Agent logic this contract enables

```python
def on_error(err: Error, attempt: int, request: Request) -> Action:
    log.warning("apex error", code=err.error_code, correlation_id=err.correlation_id,
                request_id=err.request_id)

    if err.retryable and attempt < MAX_ATTEMPTS:
        return Retry(request, after_seconds=err.retry_after or backoff(attempt))  # same Idempotency-Key

    if err.next_action:
        return Follow(err.next_action)            # e.g. GET /bookings/BK-99182/seat-map
    if err.remediation:
        return AskModel(err.remediation)          # LLM-based agents can act on the prose
    return Escalate(err.message)                  # surface to the human, stop
```

No string matching on `message`. No guessing. Unknown `error_code` values still flow through the `retryable` branch.

The IRROPS replay: the agent receives `SEAT_UNAVAILABLE`, `retryable: true`, `retry_after: 30`. It waits thirty seconds, queries the flexible flights endpoint, finds the next flight that fits her status, books it, and sends Brittany a Slack message: "Your return flight was canceled. I have booked you on the 4:15. Same cabin." She never calls support.

### 4.8 Alternative: RFC 9457 Problem Details

If your organization has standardized on **RFC 9457 Problem Details for HTTP APIs** (`application/problem+json`), use it. The fields map cleanly, with the agent-specific fields as extension members:

```json
{
  "type": "https://developer.apex-airways.example/errors/seat-unavailable",
  "title": "Seat unavailable",
  "status": 409,
  "detail": "The selected seat is no longer available.",
  "instance": "/bookings/BK-99182/seat",
  "error_code": "SEAT_UNAVAILABLE",
  "retryable": true,
  "retry_after": 30,
  "remediation": "Query /flights?origin=ORD&dest=ATL&flexible=true for available alternatives.",
  "correlation_id": "7d2c9a4e-1b3f-4c8e-9f60-2a1d5e8b7c01",
  "request_id": "3b1f7e2d-5a6c-4d8e-b9f0-1c2a3d4e5f60"
}
```

Problem Details standardizes the envelope; it does not tell the agent whether to retry. `retryable` is still the field that matters. The lint rule `agent-error-must-be-json` accepts either media type.

## 5. Governance applied

### 5.1 Lint

| Rule in [`agent-ready.spectral.yaml`](../governance/agent-ready.spectral.yaml) | What it enforces |
|---|---|
| `agent-error-must-be-json` | Every 4xx/5xx response has `application/json` or `application/problem+json` content. No `text/plain` errors. |
| `agent-error-schema-decision-fields` | The JSON error schema's `required` list includes `error_code`, `message`, `retryable`, `retry_after`, `remediation`, `correlation_id`, and `request_id`. |
| `agent-retry-after-on-throttle` | `429` and `503` responses declare a `Retry-After` header. |
| `agent-trace-headers-on-every-response` | Error responses carry trace headers too. |
| Spectral's built-in `oas3-valid-media-example` | Every error example validates against the `Error` schema, so the examples cannot drift from the contract. |

[`scripts/lint.sh`](../scripts/lint.sh) runs these against both files: *after* must pass, *before* must fail.

### 5.2 Semantic diff: changing the error format is breaking

```text
$ oasdiff breaking schemas/error-schema/before.openapi.yaml schemas/error-schema/after.openapi.yaml
10 changes: 10 error, 0 warning, 0 info
error  [response-media-type-removed]  PUT /bookings/{bookingId}/seat  removed the media type 'text/plain' for the response with the status '400'
error  [response-media-type-removed]  PUT /bookings/{bookingId}/seat  removed the media type 'text/plain' for the response with the status '409'
...
```

Existing consumers may be string-matching the old bodies, so removing `text/plain` is a breaking change. Two ways to ship it:

1. **Major version** (what this repo shows): `before` is `1.4.0` on `/v1`, `after` is `2.0.0` on `/v2`. v1 gets `Deprecation` and `Sunset` headers and a documented sunset date.
2. **Non-breaking migration inside v1:** *add* `application/json` alongside `text/plain` on each error response (adding a media type is not breaking) and serve JSON when the client sends `Accept: application/json`. Agents opt in immediately; the plain-text form is deprecated and removed in v2.

Once v2 is live, new error codes can be added in minor versions without tripping the gate, because `error_code` is an `x-extensible-enum`. Removing or renaming a code, removing a field, or changing `retryable` from boolean to anything else is still breaking and blocked.

### 5.3 Consumer-driven contract test

What Brittany's agent relies on is the *shape* of the decision fields, not the prose. The consumer pact says exactly that:

```js
// Illustrative Pact (pact-js v3 API) test owned by the consumer team.
const { PactV3, MatchersV3 } = require('@pact-foundation/pact');
const { like, boolean, integer, uuid } = MatchersV3;

const provider = new PactV3({ consumer: 'brittany-travel-agent', provider: 'apex-seats-api' });

it('a sold seat tells the agent not to retry and where to go next', () => {
  provider
    .given('seat 12C on BK-99182 is assigned to another passenger')
    .uponReceiving('a seat request for a sold seat')
    .withRequest({
      method: 'PUT',
      path: '/v2/bookings/BK-99182/seat',
      headers: { 'Idempotency-Key': uuid(), 'Content-Type': 'application/json' },
      body: { seat: '12C' },
    })
    .willRespondWith({
      status: 409,
      headers: { 'Content-Type': 'application/json' },
      body: {
        error_code: 'SEAT_UNAVAILABLE',
        message: like('Seat 12C has been assigned to another passenger.'),
        retryable: false,
        retry_after: null,
        remediation: like('Choose an AVAILABLE seat from GET /bookings/BK-99182/seat-map'),
        correlation_id: uuid(),
        request_id: uuid(),
      },
    });

  return provider.executeTest(async (mock) => {
    const action = await agentAssignSeat(mock.url, 'BK-99182', '12C');
    expect(action).toBeInstanceOf(Follow); // did not retry
  });
});
```

`message` and `remediation` use `like(...)`: the provider can reword them freely. `error_code` and `retryable` are exact: those are the contract. If Apex's implementation ever returns a sold seat as `retryable: true`, provider verification fails in CI — before an agent starts looping in production.

## 6. Adapting this to your API

1. **Inventory your current errors.** Grep the codebase and the logs for every error path. You will find more distinct failures than you expect, and several that share a status code but need different actions.
2. **Name each one** in `UPPER_SNAKE_CASE`. Write one line per code in the schema description.
3. **Decide `retryable` at the point of failure**, in code, not in a static table. Anything caused by the client's input is `false`. Timeouts, rate limits, dependency outages, and "resource not ready yet" are usually `true`.
4. **Always emit `retry_after`** for retryable errors when you know it. For 429s, you always know it.
5. **Write `remediation` as an instruction**, not an apology: which endpoint, which parameter, what to change.
6. **Define the schema once** in `components/schemas` and reference it from every 4xx/5xx. Add the lint rules so the next endpoint cannot skip it.
7. **Check your idempotency story** before telling clients a write is retryable.

## 7. Checklist

- [ ] One `Error` schema, referenced by every 4xx and 5xx response.
- [ ] JSON (`application/json` or `application/problem+json`), never `text/plain`.
- [ ] `error_code`: stable string, documented catalog, never renamed or reused.
- [ ] `message`: for humans; consumers are told not to match on it.
- [ ] `retryable`: always present, decided per occurrence.
- [ ] `retry_after`: present (nullable), mirrored in the `Retry-After` header on 429/503.
- [ ] `remediation`: present (nullable), an instruction the caller can act on.
- [ ] `correlation_id` and `request_id` in the body and headers.
- [ ] Every error status has a validated example.
- [ ] Lint rules enforce the above; the plain-text version is kept as a negative test.
- [ ] A consumer contract test pins `error_code` and `retryable` for the errors a real consumer handles.

---

**Related:** [01 — The Status Enum Pattern](01-status-enum-pattern.md) · [03 — The Idempotency-Key Header](03-idempotency-key-header.md) · [Back to the index](../README.md)
