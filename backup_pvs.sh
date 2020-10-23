#!/usr/bin/env bash

timestamp() {
  date +%Y-%m-%dT%H:%M:%S.%3NZ
}

# We need to initialize OpenStack credentials to be able to talk with the manila API
initOpenStackCredentials(){
    export OS_AUTH_URL=https://keystone.cern.ch/v3
    export OS_IDENTITY_API_VERSION=3
    export OS_USER_DOMAIN_ID=default
    export OS_APPLICATION_CREDENTIAL_NAME=${OS_USER_NAME}
    export OS_PROJECT_DOMAIN_ID=default
    export OS_APPLICATION_CREDENTIAL_ID=${OS_CREDENTIAL_ID}
    export OS_APPLICATION_CREDENTIAL_SECRET=${OS_CREDENTIAL_SECRET}
    export OS_REGION_NAME=cern
    export OS_AUTH_TYPE=v3applicationcredential
}

# Will stop the execution of the backup script if it finds any command execution error
# as all the operations are critical.
set -e

# Get job name uid through the downward API. This value is store in the labels of the pod just created by the job.
# It is required to run parallel pods in the job and be able to do simultaneously backups in parallel of different PVs.
JOB_UID=$(cat /etc/jobinfo/labels | grep 'job-name' | cut -d'=' -f2 |  tr -d '"')


# Contact the OpenStack manila API to retrieve information about each of the manila shares
# We need this to be able to mount PVs for backup
# See https://clouddocs.web.cern.ch/file_shares/programmatic_access.html
initOpenStackCredentials
MANILA_URL=$(openstack catalog show manilav2 | grep public | awk '{print $4}')

# OpenStack token issues will expire after 24h, so we can create several tokens per day
OPENSTACK_MANILA_SECRET=$(openstack token issue | grep "| id" | awk '{print $4}')

# Iterates over all the items of the repo queue identified by the job id and the init name.
while true; do
  ITEM=$(redis-cli -h redis LPOP job-${JOB_UID}-${REDIS_QUEUE_INIT_NAME}-queue)
  if [ -z "$ITEM" ]; then
    echo "No more PV to process"
    exit 0
  fi
      # Get information needed for each of the json queue elements of the repo.
      # This is needed to mount the PVs into the pods to do the backup.
      PV_NAME=$(echo "$ITEM" | jq -r '.metadata.name')

      NAMESPACE_CSI_DRIVER=$(echo $ITEM | jq -r '.spec.csi.nodeStageSecretRef.namespace')
      # We need this information to access the manila API
      MANILA_SHARE_ID=$(echo $ITEM | jq -r '.spec.csi.volumeAttributes.shareID')
      MANILA_SHARE_ACCESS_ID=$(echo $ITEM | jq -r '.spec.csi.volumeAttributes.shareAccessID')
      MANILA_EXPORT_LOCATIONS=$(curl -X GET -H "X-Auth-Token: $OPENSTACK_MANILA_SECRET" -H "X-Openstack-Manila-Api-Version: 2.45" $MANILA_URL/shares/$MANILA_SHARE_ID/export_locations)

      # Stores monitors and path of the PV, similar to
      # 137.138.121.135:6789,188.184.85.133:6789,188.184.91.157:6789:/volumes/_nogroup/337f5361-bee2-415b-af8e-53eaec1add43
      CEPHFS_PATH_PV=$(echo $MANILA_EXPORT_LOCATIONS | jq -r '.export_locations[]?.path')

      # Stores the userKey credentials needed to manually mount CephFS PVs
      MANILA_ACCESS_RULES=$(curl -X GET -H "X-Auth-Token: $OPENSTACK_MANILA_SECRET" -H "X-Openstack-Manila-Api-Version: 2.45" $MANILA_URL/share-access-rules/$MANILA_SHARE_ACCESS_ID)
      CEPHFS_USERKEY=$(echo $MANILA_ACCESS_RULES | jq -r '.access.access_key')

      # We need to export RESTIC_REPOSITORY to a new path as we now backup each of the PVs
      # separately into a different folder per PV (See https://its.cern.ch/jira/browse/CIPAAS-605)
      export RESTIC_REPOSITORY="${RESTIC_REPO_BASE}/${PV_NAME}"
      # In case there is a new PV to backup, there won't be any restic repo for it yet, so we need to create it with `restic init`
      restic list locks || restic init

      # It makes sure when the backup started and by which pod
      oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-started-at="$(timestamp)" --overwrite=true
      oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-started-by="$(hostname)" --overwrite=true

      echo mounting "$PV_NAME" in /mnt JOB_UID: "$JOB_UID" ...
      mount -t ceph "$CEPHFS_PATH_PV" -o name="$PV_NAME",noatime,secret="$CEPHFS_USERKEY" /mnt

      echo "backing up PV $PV_NAME JOB_UID: $JOB_UID ..."
      if ! restic backup /mnt --host="$PV_NAME" --tag=cronjob --tag="$PV_NAME"; then
        echo "ERROR backing up pv $PV_NAME by $(hostname)"
        oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-failure-at="$(timestamp)" --overwrite=true
        oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-failure-by="$(hostname)" --overwrite=true
      else

        echo "$PV_NAME" backed up

        # It annotates the success of the backup into the PV
        echo annotating and labeling PV "$NAME_PV" JOB_UID: "$JOB_UID" ...
        oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-success-at="$(timestamp)" --overwrite=true
        oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-success-by="$(hostname)" --overwrite=true

        # Push metrics into the prometheus group identified by cephfs_volume_last_backup{job="cephfs_backup_pv", persistentvolume="pv_name", status="backup_succeeded"} date +%s
        cat <<EOF | curl --data-binary @- ${pushgateway_service}/metrics/job/"cephfs_backup_pv"/persistentvolume/"$PV_NAME"/status/"backup_succeeded"
            # TYPE cephfs_volume_last_backup gauge
            # HELP cephfs_volume_last_backup job="cephfs_backup_pv" persistentvolume="pv_name" status="backup_succeeded"
            cephfs_volume_last_backup $(date '+%s.%N' | sed 's/N$//')
EOF
      fi
      # Unmount pv from /mnt earlier mounted
      echo unmounting "$PV_NAME" from /mnt JOB_UID: "$JOB_UID"  ...
      umount /mnt
done
