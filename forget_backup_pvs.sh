#!/usr/bin/env bash

timestamp() {
  date +%Y-%m-%dT%H:%M:%S.%3NZ
}

# Will stop the execution of the forget backup script if it finds any command execution error
set -e

# remove any stale lock (e.g. failed backups)
restic unlock

# Run restic check to verify that all data is properly stored in the repo.
if ! restic check; then
  echo "ERROR when checking restic data, it seems the data is not properly stored in the repository"
  exit 1
fi

# delete all restic snapshots with --tag to-delete
restic forget --tag to-delete --keep-last 1

# get all the host names of the snapshots
restic_snapshot_host_list=$(restic snapshots | awk '{print $4}')

oc get pv -l backup-cephfs-volumes.cern.ch/backup=true -o json | jq -c '.items | .[]' | while IFS= read -r PV_JSON; do
  PV_NAME=$(echo "$PV_JSON" | jq -r '.metadata.name')

  echo "$restic_snapshot_host_list" | grep -q "$PV_NAME"
  if [[ $? -ne 0 ] ; then
      # tag all the snapshots owned by the deleted pv to forget them during next run
      restic tag --set to-delete  $(restic snapshots | grep  $PV_NAME | awk '{print $1}')
  fi
done

# forget and prune old backups
# Both forget and prune need the exclusive lock on the whole restic repo in S3 (cannot run concurrently with backups)
# so we do both operations together
echo "Forgetting backups..."
restic forget ${restic_forget_args}
