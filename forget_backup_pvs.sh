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

# delete all but one restic snapshots with --tag to-delete
# it will keep the last restic snapshot for safeguard, then the following run will remove the last backup
# https://restic.readthedocs.io/en/latest/060_forget.html#removing-snapshots-according-to-a-policy
restic forget --tag to-delete --keep-last 1

restic_snapshot_host_list=$(restic snapshots --json | jq -r .'[] | .hostname')

# once a PV is not marked for backup anymore (label value changed, PV deleted...),
# mark any snapshot for that PV for deletion.
pv_list=$(oc get pv -l backup-cephfs-volumes.cern.ch/backup=true -o json | jq -c '.items | .[]' | jq -r '.metadata.name')

for restic_snapshot_host in "$restic_snapshot_host_list"
do
  echo "$pv_list" | grep -q "$restic_snapshot_host"
  if [[ $? -ne 0 ]] ; then
      # tag all the snapshots owned by the deleted pv to forget them during next run
      restic tag --set to-delete  $(restic snapshots --json | jq -r .'[] | select(.hostname=="$restic_snapshot_host") | .short_id')
  fi
done

# forget and prune old backups
# Both forget and prune need the exclusive lock on the whole restic repo in S3 (cannot run concurrently with backups)
# so we do both operations together
echo "Forgetting backups..."
restic forget ${restic_forget_args}
