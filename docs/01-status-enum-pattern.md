# The Status Enum Pattern

> **Principle 1 — Make the Happy Path Boring.** Determinism is a feature. When an agent gets a success response, that response should have exactly one interpretation.

| File | What it is |
|---|---|
| [`schemas/status-enum/before.openapi.yaml`](../schemas/status-enum/before.openapi.yaml) | The contract Brittany's agent integrated against: `status: "ok"`, optional fields, `next_page` pagination. |
| [`schemas/status-enum/after.openapi.yaml`](../schemas/status-enum/after.openapi.yaml) | The agent-ready contract: closed status enums, explicit nullability, one cursor name, async booking with polling. |
| [`governance/agent-ready.spectral.yaml`](../governance/agent-ready.spectral.yaml) | The lint rules that reject the *before* file and accept the *after* file. |
| [`governance/examples/status-enum.breaking-change.openapi.yaml`](../governance/examples/status-enum.breaking-change.openapi.yaml) | A "Friday afternoon" change to the *after* contract that the governance pipeline must block. |

The two schema files are a controlled experiment: they differ **only** in the concerns covered by Principle 1. Idempotency, error bodies, and trace headers are already agent-ready in both, so a diff of the two files shows the status pattern and nothing else.

---

## 1. The story

On Friday, Brittany's agent did a test run against Apex Airways' flight search. The response came back as:

```json
{ "status": "ok", "results": [ ... ] }
```

The agent parsed the array, stored the itinerary, and moved on. What it could not know (because the contract did not say) was whether `"ok"` meant *your search returned results*, *your search ran without errors*, or *we received your request*. Three different meanings, three different next steps. The agent assumed the first. Apex meant the third.

On Saturday night the same ambiguity hit the booking endpoint. A timed-out request eventually came back `status: "ok"`, and the agent treated it as a confirmed ticket. It stored the confirmation and stopped watching. By Monday morning, Brittany had two bookings, two charges, and no confirmed seat.

> Ambiguity that a human navigates is an outage that an agent creates.

A human developer who sees `"ok"` goes and reads the docs, checks the code, asks in the forum. An agent executes on what the contract says. And the contract said `type: string`.

## 2. The principle

"Make the happy path boring" comes down to four rules, each of which appears in the *after* contract:

| Rule | Why an agent cares | Where it appears in `after.openapi.yaml` |
|---|---|---|
| **Status fields are closed enums** | The agent maps each value to an action. A freeform string forces it to guess. | `BookingStatus`, `SearchStatus`, `BookingFailureReason` |
| **Stable keys** — add fields across versions, never rename or remove | The agent has your field names hard-coded. A rename breaks it without an error. | Enforced by the semantic-diff gate (section 5) |
| **Explicit nullability** | A missing key could be an error, a valid empty state, or a renamed field. A present-but-`null` key can only mean "no value yet." | `confirmation_number`, `failure_reason`, `poll_after_seconds`, `next_cursor` |
| **Consistent pagination** | Agents loop. If the cursor is `next_page` on one endpoint and `cursor` on another, loops break in hard-to-debug ways. | `next_cursor` in the response, `cursor` in the request, on every paginated endpoint |

Principle 1 also asks for **a correlation ID on every response, not just errors**. Both files already declare `X-Correlation-ID`, `X-Request-ID`, and `traceparent` on every response so that the diff stays focused. The lint rule `agent-trace-headers-on-every-response` keeps it that way.

## 3. The before state

Open [`before.openapi.yaml`](../schemas/status-enum/before.openapi.yaml). It is valid OpenAPI 3.1. Every example "works." Here is what an agent sees.

### 3.1 `status` is just a string

```yaml
Booking:
  type: object
  required: [booking_id, status]
  properties:
    status:
      type: string
      description: Booking status.
      examples: [ok]
```

The schema tells the agent the *type* of the value and nothing about its *meaning*. Is `ok` terminal? Is there a `pending`? Is there a `failed`, or does failure only ever come back as an HTTP error? The agent cannot write a branch for a value it does not know exists. If Apex later returns `"processing"`, the agent will hit whatever its default branch is, which is usually "treat it like success."

The flight search has the same problem on `FlightSearchResult.status`.

### 3.2 Optional instead of nullable

```yaml
    confirmation:
      type: string
      description: Confirmation number.
```

`confirmation` is not in `required`, so it can be absent. When it is absent, which of these is true?

- The booking is not confirmed yet.
- The booking failed.
- The server had a bug and dropped the field.
- The field was renamed in a new release.

The agent has no way to tell. Every one of those looks identical on the wire: a missing key.

### 3.3 Synchronous-looking, asynchronous-behaving

`POST /bookings` returns `200 OK` with a `status`. That shape tells the agent the operation is finished. In reality Apex's booking is asynchronous: payment and ticketing complete seconds later. The contract hides that. So the agent does not know it should wait, and it does not know where to poll.

### 3.4 One-off pagination

```yaml
        next_page:
          type: string
          description: Token for the next page of results.
```

paired with a `page` query parameter. Other Apex endpoints use `cursor`. An agent that has learned "loop while `cursor` is set" will stop after page one here, or never stop, depending on how its loop is written.

### 3.5 What governance says about the before state

Running the ruleset against the file:

```text
$ spectral lint -r governance/agent-ready.spectral.yaml schemas/status-enum/before.openapi.yaml

 274:16  error  agent-status-must-be-enum     Status field must declare a closed enum of allowed values, not a freeform string.  components.schemas.FlightSearchResult.properties.status
 281:19  error  agent-pagination-cursor-name  Use 'next_cursor' for pagination, not 'next_page'.                                 components.schemas.FlightSearchResult.properties.next_page
 298:16  error  agent-status-must-be-enum     Status field must declare a closed enum of allowed values, not a freeform string.  components.schemas.Booking.properties.status

✖ 3 problems (3 errors, 0 warnings, 0 infos, 0 hints)
```

This contract never reaches production. That is the point of putting the style guide in a pipeline instead of a wiki.

## 4. The after state

Open [`after.openapi.yaml`](../schemas/status-enum/after.openapi.yaml).

### 4.1 A closed enum with a meaning for every value

```yaml
BookingStatus:
  type: string
  enum: [PENDING, CONFIRMED, FAILED]
  description: |
    Lifecycle state of a booking. This is a closed set.
    - `PENDING` — Accepted and in progress. NOT a ticket. Poll `getBooking`.
    - `CONFIRMED` — Terminal. Ticket issued, payment captured, `confirmation_number` set.
    - `FAILED` — Terminal. No ticket, no charge. `failure_reason` is set.
    Adding a value to this enum is a breaking change and ships only in a new major version.
  x-enum-descriptions:
    PENDING: Accepted and in progress. Not a ticket. Poll getBooking.
    CONFIRMED: Terminal. Ticket issued and payment captured.
    FAILED: Terminal. No ticket issued and no charge made.
```

Three values. Each one maps to exactly one action:

| Value | Terminal? | Agent action |
|---|---|---|
| `PENDING` | No | Wait `poll_after_seconds`, then call `getBooking`. Do **not** tell the traveler they are booked. |
| `CONFIRMED` | Yes | Store `confirmation_number`. Notify the traveler. Stop polling. |
| `FAILED` | Yes | Read `failure_reason`. Surface it. Stop polling. No charge to reverse. |

Design notes:

- **UPPER_SNAKE_CASE values** read as constants, not prose. Nobody is tempted to show `CONFIRMED` to a user or compare it case-insensitively.
- **Meaning lives in the schema**, not in a separate doc page. The `description` is what an agent (or the tool manifest derived from this spec) actually reads. `x-enum-descriptions` puts the same text in a form that code generators such as OpenAPI Generator can attach to each generated constant.
- **The evolution rule is written into the contract.** "Adding a value is a breaking change" tells consumers they can safely write an exhaustive `switch`, and tells the provider team what their version bump must be.
- **The same pattern applies everywhere.** `SearchStatus` (`COMPLETE | PARTIAL`) answers the question the Friday `"ok"` could not: *is this result set complete?* An empty `results` array with `COMPLETE` is a real answer ("no flights"); with `PARTIAL` it means "try again later."

### 4.2 Explicit nullability: always present, sometimes null

```yaml
Booking:
  type: object
  required: [booking_id, status, status_updated_at, confirmation_number, failure_reason, poll_after_seconds, flight_id]
  properties:
    confirmation_number:
      type: [string, 'null']
      description: Record locator. Null unless `status` is `CONFIRMED`.
    failure_reason:
      description: Null unless `status` is `FAILED`.
      oneOf:
        - $ref: '#/components/schemas/BookingFailureReason'
        - type: 'null'
    poll_after_seconds:
      type: [integer, 'null']
      minimum: 1
      description: Seconds to wait before polling again. Null when `status` is terminal.
```

Every field is in `required`. Fields that may have no value are typed `[<type>, 'null']` (the OpenAPI 3.1 / JSON Schema 2020-12 way; in OpenAPI 3.0 you would write `nullable: true`). The result:

- A **missing key** is always a contract violation, and the consumer can treat it as a bug.
- A **`null`** always means "no value in this state," and the description says which state.
- The fields tie back to the enum: `confirmation_number` is set if and only if `CONFIRMED`; `failure_reason` if and only if `FAILED`; `poll_after_seconds` if and only if `PENDING`.

`next_cursor` on the search result follows the same rule: always present, `null` on the last page.

### 4.3 Async made explicit: 202 + poll

```yaml
  /bookings:
    post:
      description: |
        ... Booking is asynchronous: this call returns `202 Accepted` with a `Booking`
        whose `status` is `PENDING` (or, rarely, already `CONFIRMED`). A `PENDING`
        booking is NOT a ticket. ...
      responses:
        '202':
          headers:
            Location:
              description: URL of the booking resource to poll.
```

This is the async job pattern from the "Designing for the Agent Consumer" section of the talk. `202 Accepted` plus a `PENDING` status plus a `Location` header plus `poll_after_seconds` is four separate signals, all machine-readable, all saying "not done yet, here is where and when to check."

The Saturday-night replay, with this contract:

```text
POST /bookings              -> 202 { status: PENDING, confirmation_number: null, poll_after_seconds: 5 }
   (agent waits 5s)
GET  /bookings/BK-99182     -> 200 { status: PENDING, poll_after_seconds: 5 }
   (agent waits 5s)
GET  /bookings/BK-99182     -> 200 { status: CONFIRMED, confirmation_number: "QX7P2M", poll_after_seconds: null }
   (agent stores QX7P2M, notifies Brittany, stops)
```

One ticket. One charge. (The *retry* that created the second booking is the idempotency story; see [03 — The Idempotency-Key Header](03-idempotency-key-header.md).)

### 4.4 One cursor name

```yaml
    Cursor:
      name: cursor
      in: query
      description: Opaque cursor from a previous response's `next_cursor`. Omit for the first page.
```

Request parameter `cursor`, response field `next_cursor`, loop until `next_cursor` is `null`. The `Cursor` and `Limit` parameters are defined once in `components/parameters` so every paginated endpoint references the same definition. The lint rule `agent-pagination-cursor-name` rejects the common alternatives (`next_page`, `nextToken`, `page_token`, …).

### 4.5 Descriptions written for an intelligent but literal reader

Compare the `getBooking` description in the two files. *Before*: "Returns the booking ... including its current `status`." *After*: when to call it, what each status means for the caller, how long to wait, when to stop. The agent reads this paragraph to decide what to do; the lint rule `agent-operation-description-length` makes sure there is a paragraph to read.

### 4.6 Agent logic this contract enables

Because every value is known, the consumer's code is an exhaustive match with no default guess:

```python
def advance(booking: Booking) -> Action:
    match booking.status:
        case "PENDING":
            return Wait(seconds=booking.poll_after_seconds, then=GetBooking(booking.booking_id))
        case "CONFIRMED":
            return Notify(f"Booked. Confirmation {booking.confirmation_number}.")
        case "FAILED":
            return Escalate(reason=booking.failure_reason)
    # No `case _:` — an unknown value is a contract violation, not something to guess at.
    raise ContractViolation(f"Unknown booking status {booking.status!r}")
```

## 5. Governance applied

> Contracts without governance are just documents.

The talk's governance pipeline is **OpenAPI spec → Spectral lint → contract tests → semantic diff → deploy / block + notify**. Here is each stage applied to this pattern.

### 5.1 Lint: the style guide as code

These rules in [`agent-ready.spectral.yaml`](../governance/agent-ready.spectral.yaml) enforce Principle 1:

| Rule | What it enforces |
|---|---|
| `agent-status-must-be-enum` | Any property named `status` or ending in `_status` must declare `enum`. |
| `agent-status-enum-values-documented` | …and must have a `description` (which is where the per-value meanings go). |
| `agent-pagination-cursor-name` | Rejects `next_page`, `nextToken`, `page_token`, and similar. |
| `agent-trace-headers-on-every-response` | Every response, success included, declares `X-Correlation-ID`, `X-Request-ID`, `traceparent`. |
| `agent-operation-description-length` | Every operation has a description long enough to act on. |

[`scripts/lint.sh`](../scripts/lint.sh) runs the ruleset in both directions: the *after* file must pass, and the *before* file must **fail**. The before files act as negative tests for the ruleset itself. If someone loosens `agent-status-must-be-enum`, CI goes red because `before.openapi.yaml` suddenly passes.

### 5.2 Semantic diff: the before → after migration is a major version

Moving from *before* to *after* is not free. `oasdiff` reports it:

```text
$ oasdiff breaking schemas/status-enum/before.openapi.yaml schemas/status-enum/after.openapi.yaml
8 changes: 1 error, 7 warning, 0 info
error   [response-success-status-removed]      POST /bookings      removed the success response with the status '200'
warning [response-optional-property-removed]   GET /bookings/{id}  removed the optional property 'confirmation' ...
warning [response-property-enum-value-added]   GET /bookings/{id}  added the new 'CONFIRMED' enum value to the 'status' ...
...
warning [request-parameter-removed]            GET /flights        deleted the 'query' request parameter 'page'
warning [response-optional-property-removed]   GET /flights        removed the optional property 'next_page' ...
```

That is why the *after* file is `info.version: 2.0.0` served from `/v2`, and the *before* is `1.4.0` on `/v1`. The versioning policy from the talk:

- **Semantic versioning for the API.** Breaking = major.
- **Deprecation headers in responses.** While v1 and v2 run side by side, v1 responses carry `Deprecation` and `Sunset` headers (RFC 8594 defines `Sunset`) so that consumers (including agents that log response headers) see the end date without reading a changelog.
- **Sunset dates documented in the spec.** Put the date in the v1 `info.description` and on each deprecated operation (`deprecated: true`).

[`scripts/breaking-check.sh`](../scripts/breaking-check.sh) encodes the rule: breaking changes pass only if the major version goes up.

### 5.3 Semantic diff: catching the Friday-afternoon change

Three months after v2 ships, a backend developer renames `confirmation_number` to `record_locator` because it matches the new data model, and adds a `WAITLISTED` status for a new feature. They bump to `2.1.0`. That change is in [`governance/examples/status-enum.breaking-change.openapi.yaml`](../governance/examples/status-enum.breaking-change.openapi.yaml).

Spectral is happy with it. The new contract follows every style rule. **Lint alone would let it through.** The semantic diff does not:

```text
$ scripts/breaking-check.sh schemas/status-enum/after.openapi.yaml governance/examples/status-enum.breaking-change.openapi.yaml
4 changes: 2 error, 2 warning, 0 info
error   [response-required-property-removed]  POST /bookings      removed the required property 'confirmation_number' ...
error   [response-required-property-removed]  GET /bookings/{id}  removed the required property 'confirmation_number' ...
warning [response-property-enum-value-added]  POST /bookings      added the new 'WAITLISTED' enum value to the 'status' ...
warning [response-property-enum-value-added]  GET /bookings/{id}  added the new 'WAITLISTED' enum value to the 'status' ...

::error ::Breaking change without a major version bump (still v2). Block + notify.
```

Note the policy choice in `breaking-check.sh`: **it fails on warnings, not only errors.** `oasdiff` classifies a new response enum value as a warning and suggests `x-extensible-enum`. For a *status* field that is exactly the wrong advice: the whole point of the closed enum is that the agent handles every value, and `WAITLISTED` would fall straight into the "unknown status" branch. So this repo treats a new status value as breaking. (Error codes are different; see [02 — The Structured Error Schema](02-structured-error-schema.md), where `x-extensible-enum` is the right tool.)

The non-breaking way to ship the rename: **add** `record_locator` alongside `confirmation_number`, mark `confirmation_number` `deprecated: true` with a sunset date, and remove it only in v3. Stable keys: add, never rename or remove.

### 5.4 Consumer-driven contract test

The semantic diff protects against breaking *the spec*. A consumer-driven contract test protects against breaking *a specific consumer*, and it runs against the provider's real implementation. Brittany's agent team publishes what they rely on, just the parts they use:

```js
// Illustrative Pact (pact-js v3 API) test owned by the consumer team.
const { PactV3, MatchersV3 } = require('@pact-foundation/pact');
const { regex, like, uuid } = MatchersV3;

const provider = new PactV3({ consumer: 'brittany-travel-agent', provider: 'apex-bookings-api' });

it('getBooking returns a status the agent can act on', () => {
  provider
    .given('booking BK-99182 is confirmed')
    .uponReceiving('a request for a confirmed booking')
    .withRequest({ method: 'GET', path: '/v2/bookings/BK-99182' })
    .willRespondWith({
      status: 200,
      headers: { 'X-Correlation-ID': uuid() },
      body: {
        booking_id: 'BK-99182',
        status: regex('^(PENDING|CONFIRMED|FAILED)$', 'CONFIRMED'),
        confirmation_number: like('QX7P2M'),
        poll_after_seconds: null,
      },
    });

  return provider.executeTest(async (mock) => {
    const booking = await apexClient(mock.url).getBooking('BK-99182');
    expect(advance(booking)).toBeInstanceOf(Notify);
  });
});
```

The pact file this produces goes to a Pact Broker. Apex's CI verifies it before every deploy. When the `record_locator` rename lands, verification fails, the pipeline blocks, and **both** teams get the notification with the exact field and the consumer it affects. The teams align, the adapter is updated, and the deploy goes out on Tuesday with both sides ready.

### 5.5 Ownership

The contract is a shared artifact, not the backend team's private file. In practice:

- Changes to `after.openapi.yaml` go through a PR that consumer representatives review (a `CODEOWNERS` entry works well).
- Consumer pacts live in the broker, visible to the provider.
- Both teams are accountable to the same pipeline result.

## 6. Adapting this to your API

1. **Find every `status`, `state`, and `*_status` field.** For each, list the values the implementation actually emits today (logs are more honest than docs). That list becomes your `enum`.
2. **Write one sentence per value** saying what the consumer should *do*. If two values produce the same action, ask whether you need both. If one value produces two actions depending on context, split it.
3. **Mark terminal states** explicitly in the description. Agents need to know when to stop polling.
4. **Move every optional response field to required + nullable.** Say in the description which state makes it `null`.
5. **Pick one cursor name** and add the lint rule before the second endpoint is written.
6. **Add the rules to CI** in both directions (good file passes, bad file fails) so the ruleset itself is tested.
7. **Decide your enum evolution policy** and write it into the schema description. The default here (new status value = major version) is the safe one for agent consumers.

## 7. Checklist

- [ ] Every status field is an `enum` with a closed set of values.
- [ ] Every enum value has a documented meaning and a documented consumer action.
- [ ] Terminal vs. non-terminal states are explicit.
- [ ] Every response field is `required`; fields with no value are `null`, never absent.
- [ ] Async operations return `202`, a `PENDING` state, a `Location`, and a poll interval.
- [ ] One pagination vocabulary (`cursor` / `next_cursor`) across the API.
- [ ] Correlation and request IDs on every response, success included.
- [ ] Lint rules enforce the above; before-style files are kept as negative tests.
- [ ] Semantic diff blocks removed fields and new status values without a major bump.
- [ ] At least one consumer-driven contract test covers the status values a real consumer relies on.

---

**Related:** [02 — The Structured Error Schema](02-structured-error-schema.md) · [03 — The Idempotency-Key Header](03-idempotency-key-header.md) · [Back to the index](../README.md)
