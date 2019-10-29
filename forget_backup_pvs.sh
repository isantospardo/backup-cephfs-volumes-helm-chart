#!/usr/bin/env bash

timestamp() {
  date +%Y-%m-%dT%H:%M:%S.%3NZ
}

# Run restic check to verify that all data is properly stored in the repo.
restic check
[ $? -ne 0 ] && echo "ERROR when checking restic data, it seems the data is not properly stored in the repository" && exit 1

# remove any stale lock (e.g. failed backups)
restic unlock

# forget and prune old backups
# Both forget and prune need the exclusive lock on the whole restic repo in S3 (cannot run concurrently with backups)
# so we do both operations together
echo "Forgetting backups..."
restic forget --cache-dir=/cache ${restic_forget_args}
