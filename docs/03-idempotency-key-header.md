# The Idempotency-Key Header

> **Principle 3 — Agents Will Retry. Make It Safe.** Retrying is correct behavior. It is only safe if the server is prepared for it, and consumers only rely on that if the contract says so.

| File | What it is |
|---|---|
| [`schemas/idempotency-key/before.openapi.yaml`](../schemas/idempotency-key/before.openapi.yaml) | `POST /bookings` with no idempotency key and a one-line description: "Creates a booking." |
| [`schemas/idempotency-key/after.openapi.yaml`](../schemas/idempotency-key/after.openapi.yaml) | The same endpoint with a required `Idempotency-Key` header, documented replay semantics, and idempotency-specific errors. |
| [`governance/agent-ready.spectral.yaml`](../governance/agent-ready.spectral.yaml) | The lint rules that reject the *before* file and accept the *after* file. |

The two schema files differ **only** in idempotency. Status enums, the error schema, and trace headers are identical in both, so the diff isolates the idempotency contract.

---

## 1. The story

Saturday night. Brittany's agent sends `POST /bookings` for her Monday 7:10 AM flight to Atlanta. The network is slow; the agent's timeout fires before a response comes back. The agent does the right thing: it retries.

But the booking endpoint is not idempotent. The contract has no idempotency key. The server cannot tell a retry from a new request, so the second `POST` creates a second booking. A few seconds later the first one completes too. The agent stores one confirmation number. Apex now has two reservations and two charges on Brittany's card.

```text
POST /bookings        --(timeout, response lost)-->   server creates BK-99182
POST /bookings (retry) ------------------------------> server creates BK-99183
```

Monday morning: two confirmation emails, two pending charges, two boarding passes.

## 2. The principle

**Idempotency** is the property that calling an operation multiple times with the same request produces the same result as calling it once. No duplicate bookings. No duplicate charges.

The mechanism:

1. The client generates a UUID **before** making the request.
2. It sends that UUID in an `Idempotency-Key` header on every side-effecting call (`POST`, `PUT`, `PATCH`).
3. If the request times out, the client retries with the **same** UUID.
4. When the server receives a key it has already processed, it returns the original response instead of doing the work again.

And the part that is easy to skip: **this has to be in the contract**, not just in the implementation.

> "This endpoint is idempotent when an Idempotency-Key header is provided. Clients should generate a UUID per request and reuse it on retry."

The endpoint description should say it. The schema should include the header definition. The example response should show the key echoed back. If it is not in the contract, the agent will not use it. And if the agent does not use it, you will have Brittanys.

## 3. The before state

Open [`before.openapi.yaml`](../schemas/idempotency-key/before.openapi.yaml):

```yaml
  /bookings:
    post:
      operationId: createBooking
      summary: Creates a booking
      description: Creates a booking.
      parameters:
        - $ref: '#/components/parameters/CorrelationIdRequest'
        - $ref: '#/components/parameters/TraceParentRequest'
```

Look at what is missing rather than what is there:

- **No `Idempotency-Key` parameter.** Even an agent that knows the pattern has no signal that this server honors it. Many generic HTTP tools will not send a header the spec does not declare.
- **No retry semantics.** The description does not say whether a retry is safe, dangerous, or deduplicated.
- **No replay signal in the response.** The agent cannot tell "here is the booking you already made" from "here is a new booking."
- **No error for misuse.** Nothing tells a client that it reused a key with a different body.

The two examples on the `202` response tell the story. Same request, twice:

```yaml
                firstAttempt:
                  summary: Saturday night, attempt 1 (response lost to a timeout)
                  value: { booking_id: BK-99182, status: PENDING, ... }
                retry:
                  summary: Saturday night, attempt 2 — a second booking is created
                  value: { booking_id: BK-99183, status: PENDING, ... }
```

Nothing in this file is invalid OpenAPI. The problem is entirely what is absent. That is why this class of bug survives code review: there is no bad line to point at.

### What governance says about the before state

```text
$ spectral lint -r governance/agent-ready.spectral.yaml schemas/idempotency-key/before.openapi.yaml

 41:20  error  agent-idempotency-documented           Describe the idempotency guarantee in the operation description (mention 'idempotent' and 'Idempotency-Key').  paths./bookings.post.description
 41:20  error  agent-operation-description-length     Operation description is too thin for an agent to act on (minimum 150 characters).                             paths./bookings.post.description
 42:18  error  agent-idempotency-key-on-side-effects  Side-effecting operation must declare an 'Idempotency-Key' header parameter.                                   paths./bookings.post.parameters

✖ 3 problems (3 errors, 0 warnings, 0 infos, 0 hints)
```

A linter cannot see a missing concept in code review, but it can require that the concept be present in the contract.

## 4. The after state

Open [`after.openapi.yaml`](../schemas/idempotency-key/after.openapi.yaml). The guarantee is stated in three places, each aimed at a different reader.

### 4.1 In the parameter definition — for SDK generators, gateways, and agents' tool schemas

```yaml
    IdempotencyKey:
      name: Idempotency-Key
      in: header
      required: true
      description: |
        Client-generated UUID (v4 or v7) that identifies one logical operation.
        Generate it once, before the first attempt. Send the same value on every retry
        of that operation. Keys are scoped to your OAuth client and retained for 24 hours.
      schema:
        type: string
        format: uuid
      example: 550e8400-e29b-41d4-a716-446655440000
```

**Adaptation: `required: true`.** The talk's wording is "idempotent *when* an Idempotency-Key is provided." For the endpoint that charges money, this repo goes one step further and makes the header required. An optional header is a header some clients forget. A required one is enforced by every generated SDK, every schema-validating gateway, and the tool manifest an agent is given. The server answers a missing key with `400 IDEMPOTENCY_KEY_MISSING` rather than silently processing a non-deduplicated write. (See 5.2 for how to get there without breaking existing clients.)

### 4.2 In the operation description — for the agent (and the human) deciding how to call it

```yaml
      description: |
        ...
        This endpoint is idempotent when an `Idempotency-Key` header is provided, and the
        header is required. Clients should generate a UUID per request and reuse it on
        retry. Generate the key before the first attempt, persist it with your pending
        work, and send the identical key and identical body on every retry after a
        timeout, connection reset, 429, or 5xx.

        Server guarantees, for 24 hours after the first request with a given key:
        - Same key, same body, first request finished → the original status code and
          body are returned, with `Idempotent-Replayed: true` and
          `idempotency.replayed: true`. No second booking. No second charge.
        - Same key, same body, first request still running → `409` with
          `IDEMPOTENCY_KEY_IN_PROGRESS` and `retryable: true`. Wait and retry.
        - Same key, different body → `422` with `IDEMPOTENCY_KEY_REUSED` and
          `retryable: false`. This is a client bug: a new booking needs a new key.
        - 429 and 5xx outcomes are not stored, so retrying with the same key
          re-attempts the operation safely.

        Use a new key only when you intend a new, separate booking.
```

The talk's sentence is there verbatim, followed by every case a careful client has to reason about. "Persist it with your pending work" matters for agents: if the agent process restarts mid-retry and generates a fresh key, the protection is gone.

### 4.3 In a machine-readable extension — for linters and middleware

```yaml
      x-idempotency:
        header: Idempotency-Key
        required: true
        scope: oauth-client
        retention: PT24H
        fingerprint: [method, path, body]
        replayed-header: Idempotent-Replayed
```

Prose is for readers. `x-idempotency` is the same policy in a form an API gateway plugin or idempotency middleware can be configured from, and a lint rule can check for consistency. It is a vendor extension defined by this repo; rename it to fit your conventions.

### 4.4 Semantics, case by case

| Situation | Server behavior | Status | Agent action |
|---|---|---|---|
| First request with key K | Process, store response under (client, K) | `202` | Continue normally |
| Retry with K, same body, first finished | Return stored response; `Idempotent-Replayed: true` | `202` (original) | Treat as the original response |
| Retry with K, same body, first still running | Do not start a second one | `409 IDEMPOTENCY_KEY_IN_PROGRESS`, `retryable: true` | Wait `retry_after`, retry with K |
| Request with K, **different** body | Refuse | `422 IDEMPOTENCY_KEY_REUSED`, `retryable: false` | Bug. New operation needs a new key |
| No key | Refuse | `400 IDEMPOTENCY_KEY_MISSING`, `retryable: false` | Generate a key, send again |
| First attempt got `429` or `5xx` | Not stored against K | `429` / `503` | Retry with K after `Retry-After`; the operation runs fresh |
| K older than 24 hours | Treated as new | — | Do not retry across that window |

Design choices worth calling out:

- **Scope is the OAuth client**, which ties to the per-agent identity in `agentOAuth`. Two different agents cannot collide on a key, and one agent cannot replay another's response.
- **The fingerprint is method + path + body.** This is what makes `IDEMPOTENCY_KEY_REUSED` detectable. Without it, a client bug that reuses a key for a different flight would silently return the wrong booking.
- **Transient failures are not stored.** If 5xx outcomes were cached, a retry after a brief outage would replay the outage for 24 hours.
- **The replay returns the original status code** (`202`), not `200`. The consumer's success path is identical for first attempt and replay.

### 4.5 The key echoed back, in headers and body

```yaml
        '202':
          headers:
            Idempotency-Key:      { $ref: '#/components/headers/Idempotency-Key' }
            Idempotent-Replayed:  { $ref: '#/components/headers/Idempotent-Replayed' }
            ...
          content:
            application/json:
              schema: { $ref: '#/components/schemas/Booking' }
              examples:
                retryReplay:
                  summary: Saturday night, attempt 2 — same key, original booking returned
                  value:
                    booking_id: BK-99182
                    status: PENDING
                    confirmation_number: null
                    flight_id: FL-AX1142-20261005
                    idempotency:
                      key: 550e8400-e29b-41d4-a716-446655440000
                      replayed: true
                      first_seen_at: '2026-10-03T23:41:07Z'
```

**Adaptation of the slide's `"duplicate": false`.** The slide shows the retry returning `{ "confirmation": "BK-99182", "duplicate": false }`. This repo keeps the idea (tell the client explicitly that no duplicate was created) and makes it unambiguous:

- `idempotency.replayed` is `false` on the request that created the booking and `true` on every replay. "Was this a replay?" is a clearer question than "is this a duplicate?", where both answers can sound alarming.
- The key is echoed in the body as well as the header, because many agent frameworks only hand the tool the body.
- `Idempotent-Replayed` in the header lets gateways and logs see replays without parsing JSON.
- `booking_id` is the same (`BK-99182`) in both examples. That is the whole point.

`X-Request-ID` is new on a replay (it identifies *this* call), while `X-Correlation-ID` stays the same (it identifies the workflow). An auditor can see both attempts and that they resolved to one booking.

### 4.6 The Saturday night replay, with this contract

```text
Agent generates K = 550e8400-e29b-41d4-a716-446655440000 and stores it with the pending task.

POST /bookings  Idempotency-Key: K     --(timeout, response lost)-->  server creates BK-99182, stores response under K
POST /bookings  Idempotency-Key: K     ----------------------------->  server finds K
                                        <-- 202 { booking_id: BK-99182, idempotency.replayed: true }
                                            Idempotent-Replayed: true
GET  /bookings/BK-99182  (poll)         <-- 200 { status: CONFIRMED, confirmation_number: QX7P2M }
```

One ticket. One charge. Brittany walks up to the kiosk Monday with one boarding pass.

### 4.7 Client logic this contract enables

```python
def create_booking(task: PendingBooking) -> Booking:
    # Key is generated once and persisted with the task, so it survives process restarts.
    if task.idempotency_key is None:
        task.idempotency_key = str(uuid.uuid4())
        task.save()

    for attempt in range(MAX_ATTEMPTS):
        try:
            resp = http.post("/bookings", json=task.body,
                             headers={"Idempotency-Key": task.idempotency_key}, timeout=10)
        except Timeout:
            continue                                   # safe: same key, same body
        if resp.ok:
            return Booking.parse(resp.json())          # first attempt or replay, same handling
        err = Error.parse(resp.json())
        if err.retryable:                              # IN_PROGRESS, RATE_LIMITED, SERVICE_UNAVAILABLE
            sleep(err.retry_after or backoff(attempt))
            continue
        raise NonRetryable(err)                        # REUSED, MISSING, VALIDATION_FAILED
    raise GaveUp(task)
```

Notice what the client does *not* need: any knowledge of which errors are safe to retry on a write. The server's `retryable` flag plus the idempotency guarantee answer that together. See [02 — The Structured Error Schema](02-structured-error-schema.md).

### 4.8 Implementation notes (outside the contract, but worth knowing)

The talk's call to action says the implementation is a middleware layer. A typical one:

1. On request: look up (client ID, key). If found and complete, compare the fingerprint; return the stored response or `422`. If found and in progress, return `409`.
2. If not found: atomically insert (client ID, key, fingerprint, `in_progress`) (a unique constraint or `SET NX` in Redis), then call the handler.
3. On handler completion: store the status code, headers, and body; mark complete. On 429/5xx, delete the record instead.
4. Expire records after the documented retention window.

The atomic insert in step 2 is what prevents two concurrent retries from both creating bookings.

### 4.9 Standards

The header name and semantics follow the IETF HTTPAPI working group's Internet-Draft *"The Idempotency-Key HTTP Header Field"*, which several large payment APIs already implement in similar form. Using the common name matters for agents: a model or framework that has seen `Idempotency-Key` elsewhere will recognize it here.

## 5. Governance applied

### 5.1 Lint

| Rule in [`agent-ready.spectral.yaml`](../governance/agent-ready.spectral.yaml) | What it enforces |
|---|---|
| `agent-idempotency-key-on-side-effects` | Every `POST`, `PUT`, and `PATCH` declares an `Idempotency-Key` header parameter. |
| `agent-idempotency-documented` | The operation description states the guarantee (mentions "idempotent" and `Idempotency-Key`). |
| `agent-operation-description-length` | The description is a real paragraph, not "Creates a booking." |
| `agent-error-schema-decision-fields` | The `409`/`422`/`400` idempotency errors use the full error schema, so `retryable` is always there. |

Note the second rule. It is not enough for the parameter to exist; the *promise* must be written where consumers read it. [`scripts/lint.sh`](../scripts/lint.sh) keeps the *before* file as a negative test for all three.

### 5.2 Semantic diff and a migration path

```text
$ oasdiff breaking schemas/idempotency-key/before.openapi.yaml schemas/idempotency-key/after.openapi.yaml
1 changes: 1 error, 0 warning, 0 info
error  [new-required-request-parameter]  POST /bookings  added the new required 'header' request parameter 'Idempotency-Key'
```

Adding a *required* request header breaks every existing client that does not send it. Everything else in this migration (the new `409`/`422` responses, the new `idempotency` response property) is additive. So the rollout has a natural non-breaking first step:

| Version | Contract | Breaking? |
|---|---|---|
| `1.5.0` | Add `Idempotency-Key` as **optional**; document the guarantee "when provided"; add replay headers, `idempotency` body field, `409`/`422` errors | No |
| `1.5.x` | Log and measure the share of `POST /bookings` calls without a key; contact those consumers | — |
| `2.0.0` | Make the header **required**; v1 gets `Deprecation` and `Sunset` headers | Yes; major bump |

Step one is the talk's wording exactly. Step three is where this repo's *after* file ends up. [`scripts/breaking-check.sh`](../scripts/breaking-check.sh) allows the final step only because the major version changes (`1.4.0` → `2.0.0`).

### 5.3 Consumer-driven contract test

The consumer cares about one behavior: a retry with the same key returns the same booking. Pact interactions are single request/response pairs, so the test pins the replay response from a provider state in which the key has already been used:

```js
// Illustrative Pact (pact-js v3 API) test owned by the consumer team.
const { PactV3, MatchersV3 } = require('@pact-foundation/pact');
const { like, regex } = MatchersV3;

const provider = new PactV3({ consumer: 'brittany-travel-agent', provider: 'apex-bookings-api' });
const KEY = '550e8400-e29b-41d4-a716-446655440000';

it('a retry with the same Idempotency-Key returns the original booking', () => {
  provider
    .given('a booking BK-99182 was created with Idempotency-Key ' + KEY)
    .uponReceiving('a retried createBooking with the same key and body')
    .withRequest({
      method: 'POST',
      path: '/v2/bookings',
      headers: { 'Idempotency-Key': KEY, 'Content-Type': 'application/json' },
      body: { flight_id: 'FL-AX1142-20261005', passenger_id: 'AM-4471902', seat: '12C' },
    })
    .willRespondWith({
      status: 202,
      headers: { 'Idempotency-Key': KEY, 'Idempotent-Replayed': 'true' },
      body: {
        booking_id: 'BK-99182',
        status: regex('^(PENDING|CONFIRMED)$', 'PENDING'),
        idempotency: { key: KEY, replayed: true, first_seen_at: like('2026-10-03T23:41:07Z') },
      },
    });

  return provider.executeTest(async (mock) => {
    const booking = await createBookingWithRetry(mock.url, pendingTask(KEY));
    expect(booking.booking_id).toBe('BK-99182');
  });
});
```

When Apex's provider build verifies this pact, it has to set up the "key already used" state and prove that its real middleware replays. If someone later removes the middleware from the route, or changes the fingerprint so that the replay is treated as new, the pipeline fails before deploy.

### 5.4 Where to start

From the talk's Monday-morning list: **add idempotency keys to your highest-risk endpoint.** Pick the one that charges money, sends notifications, or triggers an external side effect. Just that one. Write the contract first (sections 4.1–4.3 of this document), add the lint rules, ship the middleware. The value is immediate.

## 6. Adapting this to your API

1. **List every side-effecting operation** (`POST`, `PUT`, `PATCH`, and any `DELETE` with side effects). Rank by blast radius: money, messages, external calls.
2. **Declare the header once** in `components/parameters` and reference it everywhere. Decide required vs. optional per endpoint; required for anything that moves money.
3. **Write the guarantee into each description**: the talk's sentence plus your retention window, scope, and mismatch behavior.
4. **Add the response signals**: echo the key, add a replay indicator in header and body.
5. **Add the error codes**: missing key, in-progress, reused-with-different-body, all through your standard error schema.
6. **Document retention and scope** and choose a retention longer than any realistic client retry window.
7. **Roll out optional first**, measure adoption, then make it required in a major version.

## 7. Checklist

- [ ] `Idempotency-Key` declared on every side-effecting operation, defined once in `components`.
- [ ] Required on endpoints that charge money or create irreversible side effects.
- [ ] Description states: idempotent when the key is provided; generate a UUID per request; reuse it on retry.
- [ ] Retention window and key scope documented.
- [ ] Same key + same body → original response, marked as a replay (header and body).
- [ ] Same key + in-flight → `409`, retryable.
- [ ] Same key + different body → `422`, not retryable.
- [ ] Transient failures (429, 5xx) not stored against the key.
- [ ] Key echoed in the response.
- [ ] Lint rules enforce the header and the documented guarantee.
- [ ] A consumer contract test proves a replay returns the original resource.

---

**Related:** [01 — The Status Enum Pattern](01-status-enum-pattern.md) · [02 — The Structured Error Schema](02-structured-error-schema.md) · [Back to the index](../README.md)
