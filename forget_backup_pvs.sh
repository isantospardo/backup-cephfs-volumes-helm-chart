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

# we run a removal of the backups when the main PV is deleted. It deletes all but one restic snapshots with --tag to-delete
# it will keep the last restic snapshot for safeguard
# https://restic.readthedocs.io/en/latest/060_forget.html#removing-snapshots-according-to-a-policy
restic forget --tag to-delete --keep-last 1

# we need to retrieve the hostname from the snapshots where the name of the PV is stored
restic_snapshot_hostname_list=$(restic snapshots --json | jq -r ' .[] | .hostname' | sort -u)

# it stores the pv_names in a hash table to make it easier to check if the PV exists to delete the backups
declare -A pv_list
# disables monitor mode as it separates the SubShell and we need access to the hash we are loading
set +m
shopt -s lastpipe
oc get pv -l backup-cephfs-volumes.cern.ch/backup=true -o json | jq -r '.items[].metadata.name' | while IFS= read -r pv_name; do
  pv_list["$pv_name"]="0"
  #echo ${pv_list[$pv_name]}
done

# once a PV is not marked for backup anymore (label value changed, PV deleted...),
# mark any snapshot for that PV for deletion.
for restic_snapshot_host in $restic_snapshot_hostname_list; do
  # echo $restic_snapshot_host
  # echo restic_snapshot ${pv_list[$restic_snapshot_host]}
  if [[ ! ${pv_list[$restic_snapshot_host]} ]]; then
    # tag all the snapshots owned by the deleted PV to forget them during next run
    echo "PV $restic_snapshot_host is not marked for backup anymore, setting backups to-delete"
    restic tag --set to-delete --host "$restic_snapshot_host"
  fi
done

# forget and prune old backups
# Both forget and prune need the exclusive lock on the whole restic repo in S3 (cannot run concurrently with backups)
# so we do both operations together
echo "Forgetting backups..."
restic forget ${restic_forget_args}
