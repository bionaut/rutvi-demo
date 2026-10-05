# HTTP API


In development, the fixed test tokens are `dev-token-a-user-1`, `dev-token-a-user-2`, and `dev-token-b-user-1`. Production releases require `HTTP_IDENTITIES`: a JSON object mapping bearer tokens (at least 16 bytes) to `namespace_id`, `user_id`, and `session_id` strings. Generate random tokens and supply this value at runtime; do not commit it. Identity-looking fields in request bodies are ignored.

Protected routes require `Authorization: Bearer <token>`. Caller scope and request ID are assigned at the server boundary.

| Method and path | Operation |
|---|---|
| `POST /v1/courses` | Start `course.create`; JSON body: `{"payload":{"topic":"...","audience":"..."}}` |
| `POST /v1/tasks` | Start by `service_id` or `capability`, plus `payload` |
| `GET /v1/tasks/:reference_id` | Inspect current state and owned children |
| `GET /v1/tasks/:reference_id/result` | Read status, result, and error |
| `GET /v1/tasks/:reference_id/history?after_seq=0` | Read ordered events after a sequence cursor |
| `POST /v1/tasks/:reference_id/wait` | Wait up to `timeout_ms` (0–30000); timeout does not cancel work |
| `POST /v1/tasks/:reference_id/resume` | Submit `checkpoint_id`, `response_id`, and object `payload` |
| `DELETE /v1/tasks/:reference_id` | Cancel task and owned descendants |
| `POST /v1/resolve` | Resolve a JSON `query` within the authenticated user's scope |
| `GET /live`, `GET /ready` | Unauthenticated liveness and readiness probes |

Error responses use stable `error` codes. `unauthorized` is 401; `forbidden` 403; `not_found` 404; `conflict`, `ambiguous_target`, and `ambiguous_reference` 409; `validation_error` 422; bounded `limit_exceeded` 429; dependency unavailability 503.

Example using the local dev identity:

```sh
TOKEN=dev-token-a-user-1
curl -sS -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"payload":{"topic":"Základy událostmi řízených systémů","audience":"Juniorní backendoví vývojáři"}}' \
  http://localhost:4000/v1/courses
```

The response includes `reference_id`, `task_id`, `run_id`, `service_id`, and current `status`. Use that reference for state, wait, result, history, resume, or cancel.
