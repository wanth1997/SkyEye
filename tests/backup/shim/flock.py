#!/usr/bin/env python3
"""flock -n FD for hosts without util-linux, with the same semantics: the lock
belongs to the open file description, so it outlives this process in the caller."""
import fcntl
import sys

try:
    fcntl.flock(int(sys.argv[-1]), fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)
