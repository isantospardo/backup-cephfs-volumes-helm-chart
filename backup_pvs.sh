#!/usr/bin/env bash

timestamp() {
  date +%Y-%m-%dT%H:%M:%S.%3NZ
}

# Will stop the execution of the backup script if it finds any command execution error
# as all the operations are critical.
set -e

# Get job name uid through the downward API. This value is store in the labels of the pod just created by the job.
# It is required to run parallel pods in the job and be able to do simultaneously backups in parallel of different PVs.
JOB_UID=$(cat /etc/jobinfo/labels | grep 'job-name' | cut -d'=' -f2 |  tr -d '"')

# Iterates over all the items of the repo queue identified by the job id.
while true; do
  ITEM=$(redis-cli -h redis LPOP job-$JOB_UID-queue)
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

      # Push metrics into the prometheus group identified by cephfs_volume_last_backup{job="hostname",instance="pv_name", status="backup_succeeded"} date +%s
      cat <<EOF | curl --data-binary @- ${pushgateway_service}.svc:9091/metrics/job/$(hostname)/instance/"$PV_NAME"/status/"backup_succeeded"
          # TYPE cephfs_volume_last_backup gauge
          # HELP cephfs_volume_last_backup job="hostname" instance="pv_name"  status="backup_succeeded"
          cephfs_volume_last_backup $(date '+%s.%N' | sed 's/N$//')
EOF
      # Unmount pv from /mnt earlier mounted
      echo unmounting "$PV_NAME" from /mnt JOB_UID: "$JOB_UID"  ...
      umount /mnt
done
