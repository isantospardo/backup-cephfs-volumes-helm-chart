#!/usr/bin/env bash

timestamp() {
  date +%Y-%m-%dT%H:%M:%S.%3NZ
}
# Get job name uid through the downward API. This value is store in the labels of the pod just created by the job.
# It is required to run parallel pods in the job and be able to do simultaneously backups in parallel of different PVs.
JOB_UID=$(cat /etc/jobinfo/labels | grep 'job-name' | cut -d'=' -f2 |  tr -d '"')

# Only one pod will be the first to set the init key and get a return value of 1
setnx_rv=$(redis-cli --raw -h redis SETNX job-$JOB_UID-init-complete "$(hostname)")

if [ $setnx_rv -eq 0 ]; then
    # I'm the first, initialize the queue and set the init-complete key

    oc get pv -l backup-cephfs-volumes.cern.ch/backup=true -o json | jq -c '.items | .[]' | while IFS= read -r PV_JSON; do
        # Enqueue the json of the PV in redis queue, it uses the uid of the job, so each of the queues will a different repo.
        redis-cli -h redis rpush job-$JOB_UID-queue "$PV_JSON"

        PV_NAME=$(echo "$PV_JSON" | jq -r '.metadata.name')

        # It needs to have --overwrite due to the possibility of having the annotation already there
        oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup="pv-ready-to-be-backedup-by-job-$JOB_UID" --overwrite=true
        oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-queued-at="$(timestamp)" --overwrite=true
        oc annotate pv/"$PV_NAME" backup-cephfs-volumes.cern.ch/backup-queued-by="$(hostname)" --overwrite=true
    done
    redis-cli --raw -h redis SETNX job-$JOB_UID-init-complete "$(hostname)"
else
    # Not the first pod, wait for the first pod to set init-complete key
    while [ -z "$(redis-cli --raw -h redis GET job-$JOB_UID-init-complete)" ]; do
        echo "Waiting for first pod to complete initializing the job queue"
        sleep 5s
    done
fi
