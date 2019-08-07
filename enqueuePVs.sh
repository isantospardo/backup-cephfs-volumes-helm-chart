#!/usr/bin/env bash

timestamp() {
  date +%Y-%m-%d_%T
}

# only one pod will be the first to set the init key and get a return value of 1
setnx_rv=$(redis-cli --raw -h redis SETNX job-$JOB_UID-init-complete "$(hostname)")
echo setnx_rv $setnx_rv
echo arrived one

#setnx_rv=1
if [ $setnx_rv -eq 0 ]; then
    # I'm the first, initialize the queue and set the init-complete key
    
    # Get job UID, using downward API does not work as it does not recongnice the labels 
    JOB_UID=$(oc get pod/"$(hostname)" -o json | jq '.metadata.name' | tr -d '"')
    echo JOB_UID $JOB_UID


    oc get pv -l backup-cephfs-volumes.cern.ch/backup=true -o json | jq -c '.items | .[]' | while IFS= read -r PV_JSON; do
        # Enqueue the json of the PV in redis queue
        #redis-cli -h redis rpush job-$JOB_UID-init-complete "$PV_JSON"
        redis-cli -h redis rpush job-$JOB_UID-init-complete "$PV_JSON"

        PV_NAME=$(echo "$PV_JSON" | jq '.metadata.name' | tr -d '"')

        # it needs to have overwrite due to the possibility of having the annotation already there
        #oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup="pv-ready-to-be-backedup-by-job-$JOB_ID" --overwrite=true
        oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-queued-at="$(timestamp)" --overwrite=true
        oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-queued-by="$(hostname)" --overwrite=true

        # TODO: prometheus, check if a PV was annotated as queued at <today> and the ammount of annotations with back-up failure at is <today> is more than 10% of them
        # TODO: promteheus, check if the PV it has the label to be backed up and dont have a back-up success at for three days.
        # TODO: remove show all the items in the queue
        redis-cli -h redis lrange job-$JOB_UID-init-complete 0 -1
        echo arrived two
    done
    redis-cli --raw -h redis SET job-$JOB_UID-init-complete "$(hostname)"
    echo arrived three
else
    # Not the first pod, wait for the first pod to set init-complete key
    while [ -z "$(redis-cli --raw -h redis GET job-$JOB_UID-init-complete)" ]; do
        echo "Waiting for first pod to complete initializing the job queue"
        sleep 5s
        echo arrived four
    done
fi
