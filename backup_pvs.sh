#!/usr/bin/env bash

timestamp() {
  date +%Y-%m-%d_%T
}

# Run restic check to verify that all data is properly stored in the repo.
# In case of failure, the job will exit.
set -e
restic check
[ $? -ne 0 ] && echo ERROR when checking restic data, it seems the data is not properly stored in the repository
set +e

# Get job UID. We need to do it on this way as downward API does not work as it does not recognize the labels.
JOB_UID=$(oc get pod/"$(hostname)" -o json | jq '.metadata.name' | tr -d '"')

# Iterates over all the items of the repo queue identified by the job id.
ITEM=$(redis-cli -h redis LPOP job-$JOB_UID-init-complete)
while [ -n "$ITEM" ]; do

    # Get information needed for each of the json queue elements of the repo.
    # This is needed to mount the PVs into the pods to do the backup.
    PV_NAME=$(echo "$ITEM" | jq '.metadata.name' | tr -d '"')

    NAMESPACE_CSI_DRIVER=paas-infra-cephfs
    CEPHFS_MONITORS_PV=$(echo $ITEM | jq '.spec.csi.volumeAttributes.monitors'| tr -d '"')
    CEPHFS_ROOTPATH_PV=$(echo $ITEM | jq '.spec.csi.volumeAttributes.rootPath' | tr -d '"')
    CEPHFS_SECRET_REF=$(echo $ITEM | jq '.spec.csi.nodeStageSecretRef.name' | tr -d '"')
    CEPHFS_USERID=$(oc get secret $CEPHFS_SECRET_REF -n $NAMESPACE_CSI_DRIVER -o json | jq '.data.userID' | tr -d '"' | base64 -d )
    CEPHFS_USERKEY=$(oc get secret $CEPHFS_SECRET_REF -n $NAMESPACE_CSI_DRIVER -o json | jq '.data.userKey' | tr -d '"' | base64 -d )

    #do_backup
    set -e

    # Annotates PV failure beforehand, this makes sure that if the backup fails, the annotations will still be set.
    # In any other case the annotations will be removed.
    oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-failure-at="$(timestamp)" --overwrite=true
    oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-failure-by="$(hostname)" --overwrite=true
  
    echo mounting "$PV_NAME" in /mnt JOB_ID: "$JOB_UID" ...
    mount -t ceph "$CEPHFS_MONITORS_PV":"$CEPHFS_ROOTPATH_PV"  -o name="$CEPHFS_USERID",secret="$CEPHFS_USERKEY" /mnt

    echo backing up PV "$PV_NAME" JOB_ID: "$JOB_UID" ...
    #TODO: Add optional tags, be default empty, it would be a good idea to add a tag to delete it after a period of time
    restic backup /mnt --host="$PV_NAME" --cache-dir=/cache --tag=cronjob --tag="$PV_NAME"

    # removes snapshots, a prune command will run once a week to remove the data that was referencing the snapshot from the repository
    restic unlock
    [ $? == 0 ] && restic forget --host="$PV_NAME" --cache-dir=/cache ${restic_forget_args}

    echo "$PV_NAME" backed up
    # TODO: restic cant run in parallel so we have to implement some logic here to forget backups somehow, 
    # if this would be possible we could look in a init container to have it created and before any other job started.
    # TODO: Add a new ticket to implement the removal of the backups when the main PV is deleted and probably ask to the other MR to deleted after 30 days.

    # On success: it deletes the failure annotations earlier set
    # It annotates the success of the backup into the PV
    echo annotating and labeling PV "$NAME_PV" JOB_ID: "$JOB_UID" ...
    oc annotate pv "$PV_NAME" backup-cephfs-volumes.cern.ch/backup-failure-at-
    oc annotate pv "$PV_NAME" backup-cephfs-volumes.cern.ch/backup-failure-by-
    oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-success-at="echo $(timestamp)" --overwrite=true
    oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-success-by="$(hostname)" --overwrite=true

    oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup="pv-being-backedup-by-job-$JOB_ID" --overwrite=true
    oc label pv "$PV_NAME" backup_status=succeded --overwrite=true

    # Unmount pv from /mnt earlier mounted
    echo unmounting "$PV_NAME" from /mnt JOB_ID: "$JOB_UID"  ...
    umount /mnt

    # Process next item 
    ITEM=$(redis-cli -h redis LPOP job-$JOB_UID-init-complete)
done

# Remove all keys in redis database to start from scratch next time
#redis-cli -h redis FLUSHDB