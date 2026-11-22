"""slots.py — atomic worker-slot store for agent.sh (python3 -I slots.py <op> ...).

Operations:
  acquire --state-dir D --max-workers N --wait-seconds S --owner-pid P
           --name NAME --stop-file F
      Print "lease <uuid>" once a slot is admitted; wait otherwise, 200 ms
      retries against a monotonic deadline, never holding the lock while
      sleeping. First saturation: one stderr line
      "[NAME] waiting for a worker slot (used/N)". Deadline: "agent.sh: NAME
      timed out waiting for a worker slot after Ss", exit 7. Stop file present:
      exit 6. Owner gone while waiting: exit 3, no slot claimed.
  bind --state-dir D --lease U --owner-pid P --child-pid C
      Bind the worker child's OS start identity to the lease (again per
      steering segment); exit 0. Wrong/reused owner or unknown lease: 3.
  release --state-dir D --lease U --owner-pid P
      Release a matching lease whose worker child has exited; also 0 when the
      lease is already absent; 3 on mismatched ownership or a live child.
  count --state-dir D
      Reap definitely dead holders and print the live reservation count.

Exit codes: 0 ok, 2 bad arguments, 3 state/identity error, 6 stop requested,
7 wait deadline passed. Identity of a pid is "ps -o lstart=" (LC_ALL=C,
whitespace collapsed) plus "ps -o comm=" of the owner; both must match, else
the holder is dead. A bound child execs into claude, so its comm may change
legitimately: it counts alive while the pid exists with the same start time.
D/slots.json is only ever replaced atomically under flock on D/slots.lock
(which is never unlinked); a malformed ledger fails closed (3), never reset.
"""
import argparse
import contextlib
import fcntl
import json
import os
import subprocess
import sys
import time
import uuid

VERSION = 1
LOCK_NAME = "slots.lock"
LEDGER_NAME = "slots.json"
RETRY_SECONDS = 0.2


class SlotError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def parse_args(argv):
    p = argparse.ArgumentParser(prog="slots.py", description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="op", required=True)

    def state_opt(sp):
        sp.add_argument("--state-dir", required=True)

    def pid_opt(sp, flag):
        sp.add_argument(flag, required=True, type=int)

    a = sub.add_parser("acquire")
    state_opt(a)
    a.add_argument("--max-workers", required=True, type=int)
    a.add_argument("--wait-seconds", required=True, type=int)
    pid_opt(a, "--owner-pid")
    a.add_argument("--name", required=True)
    a.add_argument("--stop-file", required=True)

    b = sub.add_parser("bind")
    state_opt(b)
    b.add_argument("--lease", required=True)
    pid_opt(b, "--owner-pid")
    pid_opt(b, "--child-pid")

    r = sub.add_parser("release")
    state_opt(r)
    r.add_argument("--lease", required=True)
    pid_opt(r, "--owner-pid")

    c = sub.add_parser("count")
    state_opt(c)

    args = p.parse_args(argv)
    if not os.path.isabs(args.state_dir):
        p.error("--state-dir must be an absolute path")
    if args.op == "acquire":
        if args.max_workers < 1:
            p.error("--max-workers must be a positive integer")
        if args.wait_seconds < 0:
            p.error("--wait-seconds must be a nonnegative integer")
        if args.owner_pid < 1:
            p.error("--owner-pid must be a positive integer")
        if not args.name or "\n" in args.name:
            p.error("--name must be nonempty")
        if not os.path.isabs(args.stop_file):
            p.error("--stop-file must be an absolute path")
    elif args.op != "count" and args.owner_pid < 1:
        p.error("--owner-pid must be a positive integer")
    return args


def ps_field(pid, field):
    """("ok", value) | ("dead", None) when ps proves the pid is gone | ("unknown", None)."""
    try:
        r = subprocess.run(["ps", "-p", str(pid), "-o", field + "="], capture_output=True,
                           text=True, timeout=5, env=dict(os.environ, LC_ALL="C"))
    except (OSError, subprocess.TimeoutExpired):
        return ("unknown", None)
    if r.returncode == 0:
        out = r.stdout.strip()
        return ("ok", " ".join(out.split())) if out else ("unknown", None)
    return ("dead", None) if not r.stdout.strip() else ("unknown", None)


def identity_of(pid):
    st, lstart = ps_field(pid, "lstart")
    st2, comm = ps_field(pid, "comm")
    if "dead" in (st, st2):
        return ("dead", None)
    if "unknown" in (st, st2):
        return ("unknown", None)
    return ("ok", (lstart, comm))


def owner_state(holder):
    """alive | dead | unknown, comparing stored identity to the current process."""
    st, ident = identity_of(holder["owner_pid"])
    if st != "ok":
        return st
    return "alive" if ident == (holder["owner_start"], holder["owner_comm"]) else "dead"


def child_is_alive(holder):
    """A bound child execs into claude, so only pid existence plus start time count."""
    cpid = holder.get("child_pid")
    if cpid is None:
        return False
    st, lstart = ps_field(cpid, "lstart")
    if st == "ok":
        return lstart == holder.get("child_start")
    return st == "unknown"  # cannot prove death: keep the reservation


def reap(ledger):  # caller holds the lock
    kept = []
    for h in ledger["holders"]:
        state = owner_state(h)
        if state == "alive" or state == "unknown" or child_is_alive(h):
            kept.append(h)
    changed = len(kept) != len(ledger["holders"])
    ledger["holders"] = kept
    return changed


def load_ledger(state_dir):
    path = os.path.join(state_dir, LEDGER_NAME)
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = f.read()
    except FileNotFoundError:
        return None
    except OSError as e:
        raise SlotError(3, f"agent.sh: cannot read the slot ledger {path}: {e}")
    try:
        data = json.loads(raw)
        if not isinstance(data, dict) or data.get("version") != VERSION:
            raise ValueError("bad version")
        if not isinstance(data.get("holders"), list) or not isinstance(data.get("capacity"), int):
            raise ValueError("bad shape")
    except ValueError:
        raise SlotError(3, f"agent.sh: malformed slot ledger {path}; not resetting it")
    return data


def save_ledger(state_dir, ledger):  # caller holds the lock
    tmp = os.path.join(state_dir, "." + LEDGER_NAME + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(ledger, f)
        f.flush()
        os.fsync(f.fileno())
        os.fchmod(f.fileno(), 0o600)
    os.replace(tmp, os.path.join(state_dir, LEDGER_NAME))


@contextlib.contextmanager
def ledger_lock(state_dir, create_dir):
    if create_dir:
        os.makedirs(state_dir, mode=0o700, exist_ok=True)
        os.chmod(state_dir, 0o700)
    fd = os.open(os.path.join(state_dir, LOCK_NAME), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)  # releases the flock; the lock file itself is never unlinked


def find(ledger, lease):
    for h in ledger["holders"]:
        if h.get("lease") == lease:
            return h
    return None


def op_acquire(a):
    deadline = time.monotonic() + a.wait_seconds
    announced = False
    first = None
    while True:
        if os.path.exists(a.stop_file):
            return 6
        st, ident = identity_of(a.owner_pid)
        if st == "dead" or (first is not None and ident != first):
            raise SlotError(3, f"agent.sh: {a.name} owner process {a.owner_pid} is gone")
        if st == "unknown":
            raise SlotError(3, f"agent.sh: {a.name} cannot determine the identity of "
                               f"owner {a.owner_pid}")
        first = first or ident
        with ledger_lock(a.state_dir, create_dir=True):
            ledger = load_ledger(a.state_dir)
            if ledger is None:
                ledger = {"version": VERSION, "capacity": a.max_workers, "holders": []}
            reap(ledger)
            if ledger["holders"] and ledger["capacity"] != a.max_workers:
                raise SlotError(3, f"agent.sh: {a.name} conflicting --max-workers "
                                   f"{a.max_workers}: {len(ledger['holders'])} holder(s) "
                                   f"run with limit {ledger['capacity']}")
            ledger["capacity"] = a.max_workers
            if len(ledger["holders"]) < a.max_workers:
                st2, ident2 = identity_of(a.owner_pid)  # prove the owner again before claiming
                if st2 != "ok" or ident2 != first:
                    raise SlotError(3, f"agent.sh: {a.name} owner process {a.owner_pid} "
                                       f"is gone")
                lease = str(uuid.uuid4())
                ledger["holders"].append({
                    "lease": lease, "owner_pid": a.owner_pid,
                    "owner_start": ident2[0], "owner_comm": ident2[1], "name": a.name,
                    "child_pid": None, "child_start": None, "child_comm": None})
                save_ledger(a.state_dir, ledger)
                print(f"lease {lease}")
                return 0
            used = len(ledger["holders"])
        if not announced:
            print(f"[{a.name}] waiting for a worker slot ({used}/{a.max_workers})",
                  file=sys.stderr)
            announced = True
        now = time.monotonic()
        if now >= deadline:
            print(f"agent.sh: {a.name} timed out waiting for a worker slot "
                  f"after {a.wait_seconds}s", file=sys.stderr)
            return 7
        time.sleep(min(RETRY_SECONDS, deadline - now))


def op_bind(a):
    with ledger_lock(a.state_dir, create_dir=True):
        ledger = load_ledger(a.state_dir)
        h = None if ledger is None else find(ledger, a.lease)
        if h is None:
            raise SlotError(3, f"agent.sh: unknown lease {a.lease} in {a.state_dir}")
        st, ident = identity_of(a.owner_pid)
        if st != "ok":
            raise SlotError(3, f"agent.sh: cannot verify owner {a.owner_pid}")
        if a.owner_pid != h["owner_pid"] or ident != (h["owner_start"], h["owner_comm"]):
            raise SlotError(3, f"agent.sh: lease {a.lease} does not belong to owner "
                               f"{a.owner_pid}")
        stc, child = identity_of(a.child_pid)
        if stc != "ok":
            raise SlotError(3, f"agent.sh: cannot determine the identity of child "
                               f"{a.child_pid}")
        h["child_pid"], h["child_start"], h["child_comm"] = a.child_pid, child[0], child[1]
        save_ledger(a.state_dir, ledger)
    return 0


def op_release(a):
    if not os.path.isdir(a.state_dir):
        return 0  # nothing was ever admitted there
    with ledger_lock(a.state_dir, create_dir=False):
        ledger = load_ledger(a.state_dir)
        h = None if ledger is None else find(ledger, a.lease)
        if h is None:
            return 0  # already absent
        st, ident = identity_of(a.owner_pid)
        if a.owner_pid != h["owner_pid"] or st != "ok" \
                or ident != (h["owner_start"], h["owner_comm"]):
            raise SlotError(3, f"agent.sh: lease {a.lease} does not belong to owner "
                               f"{a.owner_pid}")
        if child_is_alive(h):
            raise SlotError(3, f"agent.sh: lease {a.lease} still has a live worker child "
                               f"{h['child_pid']}")
        ledger["holders"].remove(h)
        save_ledger(a.state_dir, ledger)
    return 0


def op_count(a):
    if not os.path.isdir(a.state_dir) or load_ledger(a.state_dir) is None:
        print(0)
        return 0
    with ledger_lock(a.state_dir, create_dir=False):
        ledger = load_ledger(a.state_dir)
        if ledger is None:
            print(0)
            return 0
        if reap(ledger):
            save_ledger(a.state_dir, ledger)
        print(len(ledger["holders"]))
    return 0


OPS = {"acquire": op_acquire, "bind": op_bind, "release": op_release, "count": op_count}


def main(argv):
    args = parse_args(argv)
    try:
        return OPS[args.op](args)
    except SlotError as e:
        print(e.message, file=sys.stderr)
        return e.code


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as e:  # fail closed on anything unexpected
        print(f"agent.sh: slots.py error: {e}", file=sys.stderr)
        sys.exit(3)
