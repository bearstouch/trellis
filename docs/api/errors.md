# Errors (API-06)

Errors follow JSON-RPC 2.0:

```json
{"jsonrpc":"2.0","id":7,"error":{"code":-32000,"message":"Revision conflict","data":{"code":"CONFLICT","retryable":false,"expectedRevision":12,"currentRevision":13}}}
```

## JSON-RPC codes

| Code | Meaning |
| --- | --- |
| `-32700` | Parse error, including invalid UTF-8. The connection is closed afterwards. |
| `-32600` | Invalid request, a batch, or a mutating notification |
| `-32601` | Method not found |
| `-32602` | Invalid params. `data.fields` holds per-field details. |
| `-32603` | Internal error |
| `-32000` | Application error. `data.code` holds one of the codes below. |

## Application codes

| `data.code` | When | Retryable |
| --- | --- | --- |
| `AUTH_REQUIRED` | Not authenticated, authentication failed, or the grant has expired or been revoked | no |
| `PERMISSION_DENIED` | A capability is missing, the call needs all-windows scope, a host needs approving again, or a pane is bound to a host outside scope | no |
| `NOT_FOUND` | The resource doesn't exist, **or** is outside the grant's scope | no |
| `CONFLICT` | Revision mismatch (`expectedRevision`, `currentRevision`), an idempotency key reused, a layout conflict, or a duplicate theme ID | Only while the original keyed call is still running |
| `INVALID_STATE` | The operation isn't valid for the resource's current state, for example changing a built-in theme | Sometimes |
| `CONFIRMATION_REQUIRED` | A container holds running sessions and `allowRunning` wasn't set. `sessionIds` lists them. | no |
| `CLOSE_PENDING` | Graceful termination is still under way. Send `force: true` after the 2-second grace period. | yes |
| `LIMIT_EXCEEDED` | A frame or response is too big, too many authentication attempts, too many idempotency keys or subscriptions, input too large, or the input queue is full | Usually yes |
| `REMOTE_DISCONNECTED` | Input or `session.execute` for a [remote workspace](../features/remote-workspaces.md) session whose host isn't connected. Nothing is queued; the session keeps running on the host. | yes, after it reconnects |
| `LAUNCH_FAILED` | The process couldn't be started. `session` holds the failed session record. | no |
| `INVALID_CURSOR` | An output cursor or event sequence from another session or instance, or one that's ahead of the current position | no |
| `UNSUPPORTED_VERSION` | The protocol, layout or theme version isn't supported | no |

Layout errors also include `issues: [{key?, message}]`. Inside a `layout.apply` result, a failed launch can show up as `launches[].error`.

## Rules for error payloads

- Messages are sanitized. They never include tokens or full terminal input or output.
- An error should name the target resource and say how to recover.
- New error codes are SCREAMING_SNAKE strings. Add them to this page, to `knownErrorCodes` in diagnostics, and to the CLI's [exit-code mapping](cli.md#exit-codes).
