# Background refresh recovery

The combined background refresh bridge writes an atomic, versioned journal at
`LC_HOME_PATH/Library/Application Support/LiveContainerRefresh/refresh.json`.
It records the task ID, start time, launching/refreshing stage and stage time,
and the last completed outcome: success, failure, cancelled or interrupted.
Failures retain only their error domain and code, not account-bearing messages,
certificates, credentials or signing keys. Direct foreground operations inside
SideStore continue using SideStore's existing state handling.

Before launching an extension, the bridge acquires a nonblocking `flock` lease
and saves the launching stage. It saves the refreshing stage before sending the
refresh RPC. The lease spans the task, including process teardown on failure.
Both ordinary completion and cancellation release it. Concurrent bridge tasks
in different processes are rejected with the existing busy message.

A process death releases the lease in the kernel. On the next host/guest launch,
or when the Settings refresh-status section is displayed, recovery acquires
this lease before examining the journal. A saved active attempt with no living
owner is changed to interrupted and cleared from the active slot. A living
owner is never recovered merely because its timestamp is old. Task IDs prevent
stale completions from releasing another task's lease. The lock files are never
removed, so another process cannot lock a different inode under the same name.
LiveProcess holds a separate worker lease around the actual intent. Recovery and
new attempts probe both leases: a living extension remains protected after its
coordinator dies. The worker validates the active task ID and refreshing phase
under its lease, rejecting stale RPCs before calling any signing work. The
built-in worker exits when its coordinator XPC connection is interrupted or
invalidated, releasing its lease instead of waiting indefinitely for a reply.
Probe
leases span journal replacement so ID validation cannot race with a new attempt.

The Settings section shows starting, refreshing and last-result states plus
start time, with English, Simplified Chinese and Traditional Chinese copy.
Polling is limited to the lifetime of the Settings view and updates the view
only when the snapshot changes. Standalone hosts do not load this optional
support framework or display the section.

Interrupted means that completion was not confirmed, including termination
between an actual operation finishing and its completion record being written.
Recovery does not report that operation as successful or failed, kill a process
using a persisted PID, resume an old XPC connection, delete application data,
or automatically replay an installation. Check signing status in SideStore's
My Apps before retrying. Existing task/generation isolation remains in force.

If initial or phase persistence fails, the bridge fails before sending refresh
work. If final persistence fails, it releases the lease but preserves the actual
operation result; the next read reports an unconfirmed result. Corrupt JSON is
quarantined under the lease. Unknown newer schema versions and filesystem errors
are preserved and fail closed. iOS journal writes use protection until first
user authentication, allowing locked-device access after the first unlock.
Recovery is for process interruption; an atomic rename is not a guarantee about
all storage-device or sudden-power-loss behavior.

CI compiles the production journal and kills real subprocess owners during both
launching and refreshing. It verifies living-owner protection across processes,
concurrent rejection, a living orphan worker after coordinator death, stale RPCs
and callbacks, idempotent recovery, retriable leases,
terminal results, corrupt-record quarantine, forward-schema protection and an
actual failed atomic completion write. Full Xcode/IPA checks cover integration.
Device QA must still cover iOS suspension, lock-screen behavior, extension
termination and an installation already accepted by the system service.
