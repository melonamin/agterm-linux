---
worth: yes
where: agterm/Control/ControlServer.swift:163
added: 2026-08-09
---
# control socket bind unlinks a LIVE socket, orphaning the running instance

`start()` unlinks the resolved socket path unconditionally before `bind`:

```swift
// unlink any stale socket file first (a force-quit that skipped applicationWillTerminate leaves one).
unlink(socketPath)
```

The comment states the intent, but nothing distinguishes a stale path from one a running server is
listening on. So any second instance resolving the same path deletes the first instance's socket file and
binds its own. The first keeps its `listenFD` open and never learns it is unreachable, and when the second
exits, `stop()` unlinks again, leaving no path at all. Only restarting the first app recovers it.

Hit for real: a Debug build launched from another worktree without `AGTERM_STATE_DIR` killed the deployed
app's control socket. `lsof -p <pid>` showed the deployed app still holding
`unix .../agterm/agterm.sock` while `ls` found no such file, and every `agtermctl` and revdiff call failed
with `No such file or directory`.

Fix is the standard stale-socket probe: `connect()` to the path first. Success means a live server owns it,
so log and return without binding (start already tolerates bind failure without blocking launch).
`ECONNREFUSED` or `ENOENT` means stale, and only then unlink. Worth a test that a second `ControlServer`
on the same path refuses instead of stealing.

`control-api.md` describes the current behavior as "unlinks stale paths", which is the intended behavior
rather than the implemented one; update it with the fix.
