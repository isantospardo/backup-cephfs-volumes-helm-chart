#!/usr/bin/env bash

timestamp() {
  date +%Y-%m-%d_%T
}

# Get job UID, downward API does not work as it does not recongnice the labels
JOB_UID=$(oc get pod/"$(hostname)" -o json | jq '.metadata.name' | tr -d '"')
echo JOB_UID $JOB_UID

# Iterates over all the items of the queue identified by the job id
ITEM=$(redis-cli -h redis LPOP job-$JOB_UID-init-complete)
echo ITEM $ITEM
while [ -n "$ITEM" ]; do

    # extratcst general information of the json queue elements
    PV_NAME=$(echo "$ITEM" | jq '.metadata.name' | tr -d '"')

    NAMESPACE_CSI_DRIVER=paas-infra-cephfs
    CEPHFS_MONITORS_PV=$(echo $ITEM | jq '.spec.csi.volumeAttributes.monitors'| tr -d '"')
    CEPHFS_ROOTPATH_PV=$(echo $ITEM | jq '.spec.csi.volumeAttributes.rootPath' | tr -d '"')
    CEPHFS_SECRET_REF=$(echo $ITEM | jq '.spec.csi.nodeStageSecretRef.name' | tr -d '"')
    CEPHFS_USERID=$(oc get secret $CEPHFS_SECRET_REF -n $NAMESPACE_CSI_DRIVER -o json | jq '.data.userID' | tr -d '"' | base64 -d )
    CEPHFS_USERKEY=$(oc get secret $CEPHFS_SECRET_REF -n $NAMESPACE_CSI_DRIVER -o json | jq '.data.userKey' | tr -d '"' | base64 -d )

    #do_backup
    set -e

    # on failure: annotate PV beforehand, this makes sure that if the backup fails, the annotations will be set, in any other case the annotations will be removed
    oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-failure-at="$(timestamp)" --overwrite=true


    oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-failure-by="$(hostname)" --overwrite=true
    # + some human-readable annotations to know which pod did a certain backup for troubleshooting


    #on backup start: oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-started-at="<some timestamp>" --overwrite=true
    echo mounting "$PV_NAME" in /mnt ...
    echo mount -t ceph "$CEPHFS_MONITORS_PV":"$CEPHFS_ROOTPATH_PV"  -o name="$CEPHFS_USERID",secret="$CEPHFS_USERKEY" /mnt
    mount -t ceph "$CEPHFS_MONITORS_PV":"$CEPHFS_ROOTPATH_PV"  -o name="$CEPHFS_USERID",secret="$CEPHFS_USERKEY" /mnt

    # Backup logic
    echo backing up pv "$PV_NAME" ...

    #TODO: Add optional tags, be defualt empty, it would be a good idea to add a tag to delete it after a perdiod of time
    restic backup /mnt --host=ITEM="$PV_NAME" --cache-dir=/cache --tag=cronjob #--tag={{ .name }}
    # prune old backups if backup was successful
    [ $? == 0 ] && restic keep-yearly 3 --keep-monthly 3 --keep-daily 3

    #[ $? == 0 ] && restic forget --host={{ .name }} --cache-dir=/cache --prune --keep-yearly 3 --keep-monthly 3 --keep-daily 3

    # TODO: restic cant run in parallel so we have to implement some logic here to forget backups somehow, if this would be possible we could look in a init container to have it created and before any other job started.
    # TODO: Add a new ticket to implement the removal of the backups when the main PV is deleted and probably ask to the other MR to deleted after 30 days.

    echo "$PV_NAME" backed up


    # on success: it deletes the failure annotations
    oc annotate pv "$PV_NAME" backup-cephfs-volumes.cern.ch/backup-failure-at-
    oc annotate pv "$PV_NAME" backup-cephfs-volumes.cern.ch/backup-failure-by-
    oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-success-at="echo $(timestamp)" --overwrite=true
    oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-success-by="$(hostname)" --overwrite=true



    echo annotating and labeling PV "$NAME_PV" ...
    oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup="pv-being-backedup-by-job-$JOB_ID" --overwrite=true
    oc label pv "$PV_NAME" backup_status=succeded --overwrite=true

    # unmount pv from /data earlier mounted
    echo unmounting "$PV_NAME" from /data ...
    umount /mnt

    # next item
    ITEM=$(redis-cli -h redis LPOP job-$JOB_UID-init-complete)

done

## get all items
echo it should be empty
redis-cli -h redis lrange job-$JOB_UID-init-complete 0 -1







#retrieve_next_item () {
#
#    ITEM=$(redis-cli -h redis LPOP job-$JOB_UID-init-complete)
#
#    PV_NAME=$(echo "$ITEM" | jq '.metadata.name' | tr -d '"')
#
#    NAMESPACE_CSI_DRIVER=paas-infra-cephfs
#    CEPHFS_MONITORS_PV=$(echo $ITEM | jq '.spec.csi.volumeAttributes.monitors')
#    CEPHFS_ROOTPATH_PV=$(echo $ITEM | jq '.spec.csi.volumeAttributes.rootPath')
#    CEPHFS_SECRET_REF=$(echo $ITEM | jq '.spec.csi.nodeStageSecretRef.name' | tr -d '"')
#    CEPHFS_USERID=$(oc get $CEPHFS_SECRET_REF -n $NAMESPACE_CSI_DRIVER -o json | jq '.data.userID' | base64 -d )
#    CEPHFS_USERKEY=$(oc get secrets/$CEPHFS_SECRET_REF -n $NAMESPACE_CSI_DRIVER -o json | jq '.data.userKey' | base64 -d)
#
#}
#
#ITEM=$(retrieve_next_item)
#echo item = $ITEM
#
#
#do_backup () {
#
#
#    set -e
#
#    # on failure: annotate PV beforehand, this makes sure that if the backup fails, the annotations will be set, in any other case the annotations will be removed
#    oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-failure-at="echo $(timestamp)" --overwrite=true
#    oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-failure-by="$(hostname)" --overwrite=true
#    # + some human-readable annotations to know which pod did a certain backup for troubleshooting
#
#
#    on backup start: oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-started-at="<some timestamp>" --overwrite=true
#    echo mounting "$PV_NAME" in /data ...
#    mount -t ceph "$CEPHFS_MONITORS_PV":"$CEPHFS_ROOTPATH_PV"  -o name="$CEPHFS_USERID", secretfile="$CEPHFS_USERKEY" /mnt
#
#    # Backup logic
#    echo backing up pv "$PV_NAME" ...
#
#    #TODO: Add optional tags, be defualt empty, it would be a good idea to add a tag to delete it after a perdiod of time
#    #restic backup /data --host=ITEM="$PV_NAME" --cache-dir=/cache --tag={{ .name }} --tag=cronjob
#    # prune old backups if backup was successful
#    #[ $? == 0 ] && restic forget --host={{ .name }} --cache-dir=/cache --prune --keep-yearly 3 --keep-monthly 3 --keep-daily 3
#
#    # TODO: restic cant run in parallel so we have to implement some logic here to forget backups somehow, if this would be possible we could look in a init container to have it created and before any other job started.
#    # TODO: Add a new ticket to implement the removal of the backups when the main PV is deleted and probably ask to the other MR to deleted after 30 days.
#
#    echo "$PV_NAME" backed up
#
#
#    # on success: it deletes the failure annotations
#    oc annotate pv "$PV_NAME" backup-cephfs-volumes.cern.ch/backup-failure-at-
#    oc annotate pv "$PV_NAME" backup-cephfs-volumes.cern.ch/backup-failure-by-
#    oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-success-at="echo $(timestamp)" --overwrite=true
#    oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-success-by="$(hostname)" --overwrite=true
#
#
#
#    echo annotating and labeling PV "$NAME_PV" ...
#    oc annotate pv/"$NAME_PV" backup-cephfs-volumes.cern.ch/backup="pv-being-backedup-by-job-$JOB_ID" --overwrite=true
#    oc label pv "$NAME_PV" backup_status=succeded --overwrite=true
#
#    # unmount pv from /data earlier mounted
#    echo unmounting "$NAME_PV" from /data ...
#    umount /mnt
#
#    # Iterate to next ITEM of the queue
##    echo $(redis-cli -h redis LPOP job-init-complete) > ITEM
#    ITEM2=$(echo $ITEM | tr ',' '\\')
#
#}
#
#
#ITEM=$(retrieve_next_item)
#until [ -n "$ITEM" ]; do
#
#    do_backup $ITEM
#    ITEM=$(retrieve_next_item)
#
#done
#
#
## get all items
#echo it should be empty
#redis-cli -h redis lrange job-init-complete 0 -1
#
## Remove all keys in Redis database to start from scratch nex time
##redis-cli -h redis FLUSHDB
