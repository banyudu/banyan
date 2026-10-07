# Telemetry

Banyan can send OpenTelemetry traces to Axiom. Telemetry is opt-in: no exporter
or network session is created without an enabled configuration and a nonempty
API token. Local performance diagnostics continue to work independently.

Add this block to `~/.banyan/config.yml`, alongside `session_launches:`:

```yaml
telemetry:
  axiom_api_token: "YOUR_AXIOM_API_TOKEN"
  axiom_dataset: banyan-logs
  enabled: true
```

The dataset defaults to `banyan-logs`; `enabled` defaults to true when a token is
present. Existing `~/.banyan/telemetry.yml` configurations (wrapped or flat keys)
take precedence. Without either file's telemetry settings, the existing
`AXIOM_API_TOKEN` / `AXIOM_TOKEN` / `BANYAN_AXIOM_TOKEN` environment fallback and
optional dataset/org variables still work. An explicitly disabled or empty
telemetry section suppresses environment fallback. `axiom_org_id` remains an
optional setting. Config files and credentials must stay out of the repository.

## Export and context

The exporter sends OTLP/HTTP JSON to `https://api.axiom.co/v1/traces`, with bearer
authentication and `X-Axiom-Dataset` (plus `X-Axiom-Org-ID` when configured).
Spans include resource service/version, random trace/span IDs, parent span IDs,
start/end nanoseconds, span kind, status, and structured diagnostic attributes.
HTTP calls inject W3C `traceparent`. Task-local context links child operations;
queue-based subprocess/performance work captures context before dispatch.
Detached tasks must pass context explicitly if they belong to an existing trace.

Direct OTLP export avoids adding an SDK/dependency graph to the macOS app.
Swift distributed tracing would still need an exporter adapter. Ordinary JSON
ingest alone lacks the OTLP schema and tracing behavior required here. This
implementation uses real OTLP spans for structured diagnostics and timing;
it does not install global URLSession interception or a separate log exporter.

Instrumented paths include Linear HTTP, update checks and package downloads,
GitHub CLI operations, both synchronous and asynchronous SubprocessRunner entry
points, the Linux owned tmux-daemon spawn (without routing it through the generic
runner), sampled local performance events, app launch, session selection through
terminal readiness, and sidebar mode changes. CLI operations are internal spans;
only real HTTP requests carry HTTP method/status attributes. Exporter requests
bypass instrumentation to prevent recursion.

Only allowlisted structural attributes leave the machine. Command arguments,
working directories, stdout/stderr, prompts, headers, bodies, hostnames of the
local machine, and free-form performance details are excluded. Executables are
reduced to known tool names. HTTP URLs omit credentials, query, fragment, and
arbitrary paths; only the known Linear `/graphql` route is retained. Session and
correlation IDs are exported only when they are UUIDs. SQLite retains local
performance detail. Existing sampling, slow-event thresholds and local-only
`supervisor.*` policy remain in effect.

## Delivery limits

Spans batch at 100, with a 1,000-span pending cap and one in-flight request.
A one-shot 30-second flush runs only with buffered work. Flush completion waits
for responses; termination first drains performance work, then waits up to three
seconds for export. Shutdown rejects later spans and cancels its own outstanding
request on timeout. Export redirects are refused to protect bearer credentials.

Delivery is best effort. Full buffers and failed requests drop spans; export
results count accepted/dropped spans and failed requests. Failures produce only
numeric local diagnostics. There is no persistent spool or automatic retry,
which bounds resource use and avoids retry traffic during outages. Partial OTLP
success counts rejected spans and never retries them. A crash or prolonged
outage can lose telemetry.

## Verification

Run isolated fake-network regression coverage:

```sh
swift test --filter 'AxiomExporterTests|TelemetryConfigTests|PerformanceTelemetryTests|SubprocessRunnerTests'
```

With an existing active configuration, explicitly opt in to a synthetic smoke:

```sh
BANYAN_TELEMETRY_SMOKE=1 swift test --filter telemetryConfiguredLiveSmoke
```

This emits two spans with a unique marker, probes the dataset schema, and queries
back the generated trace ID and parent relation. Query permission is required in
addition to ingest permission. Credentials and server error bodies are never
printed. The smoke does not launch or restart Banyan or touch terminal sessions.
It is disabled during ordinary tests. With no active configuration it reports
that live verification is pending.

The supervisor still needs to run the packaged app and inspect its lifecycle,
HTTP/CLI and session-switch traces in Axiom's OpenTelemetry dashboard. Synthetic
API verification does not satisfy that visual app check.

References: [Axiom OTel ingestion](https://axiom.co/docs/send-data/opentelemetry),
[OTLP JSON encoding](https://opentelemetry.io/docs/specs/otlp/#json-protobuf-encoding),
[OTel trace API](https://opentelemetry.io/docs/specs/otel/trace/api/), and
[Axiom trace exploration](https://axiom.co/docs/query-data/traces).
