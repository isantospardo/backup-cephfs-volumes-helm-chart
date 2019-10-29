#!/usr/bin/env bash

timestamp() {
  date +%Y-%m-%dT%H:%M:%S.%3NZ
}

# Will stop the execution of the backup script if it finds any command execution error
# as all the operations are critical.
set -e

# Run restic check to verify that all data is properly stored in the repo.
if ! restic check; then
  echo "ERROR when checking restic data, it seems the data is not properly stored in the repository"
  exit 1
fi

# Get job UID. We need to do it on this way as downward API does not work as it does not recognize the labels.
JOB_UID=$(oc get pod/"$(hostname)" -o json | jq -r '.metadata.name')

# Iterates over all the items of the repo queue identified by the job id.
while true; do
  ITEM=$(redis-cli -h redis LPOP job-$JOB_UID-init-complete)
  if [ -z "$ITEM" ]; then
    echo "No more PV to process"
    exit 0
  fi
      # Get information needed for each of the json queue elements of the repo.
      # This is needed to mount the PVs into the pods to do the backup.
      PV_NAME=$(echo "$ITEM" | jq -r '.metadata.name')

      NAMESPACE_CSI_DRIVER=$(echo $ITEM | jq -r '.spec.csi.nodeStageSecretRef.namespace')
      CEPHFS_MONITORS_PV=$(echo $ITEM | jq -r '.spec.csi.volumeAttributes.monitors')
      CEPHFS_ROOTPATH_PV=$(echo $ITEM | jq -r '.spec.csi.volumeAttributes.rootPath')
      CEPHFS_SECRET_REF=$(echo $ITEM | jq -r '.spec.csi.nodeStageSecretRef.name')
      CEPHFS_USERID=$(oc get secret $CEPHFS_SECRET_REF -n $NAMESPACE_CSI_DRIVER -o json | jq -r '.data.userID' | base64 -d )
      CEPHFS_USERKEY=$(oc get secret $CEPHFS_SECRET_REF -n $NAMESPACE_CSI_DRIVER -o json | jq -r '.data.userKey' | base64 -d )

      # It makes sure when the backup started and by which pod
      oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-started-at="$(timestamp)" --overwrite=true
      oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-started-by="$(hostname)" --overwrite=true

      echo mounting "$PV_NAME" in /mnt JOB_UID: "$JOB_UID" ...
      mount -t ceph "$CEPHFS_MONITORS_PV":"$CEPHFS_ROOTPATH_PV"  -o name="$CEPHFS_USERID",noatime,secret="$CEPHFS_USERKEY" /mnt

      echo "backing up PV $PV_NAME JOB_UID: $JOB_UID ..."
      if ! restic backup /mnt --host="$PV_NAME" --cache-dir=/cache --tag=cronjob --tag="$PV_NAME"; then
        echo "ERROR backing up pv $PV_NAME by $(hostname)"
        oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-failure-at="$(timestamp)" --overwrite=true
        oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-failure-by="$(hostname)" --overwrite=true
      fi

      echo "$PV_NAME" backed up

      # It annotates the success of the backup into the PV
      echo annotating and labeling PV "$NAME_PV" JOB_UID: "$JOB_UID" ...
      oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-success-at="$(timestamp)" --overwrite=true
      oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-success-by="$(hostname)" --overwrite=true

      # Unmount pv from /mnt earlier mounted
      echo unmounting "$PV_NAME" from /mnt JOB_UID: "$JOB_UID"  ...
      umount /mnt
done
