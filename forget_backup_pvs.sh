#!/usr/bin/env bash

# Will stop the execution of the forget backup script if it finds any command execution error
set -e

# Get job name uid through the downward API. This value is store in the labels of the pod just created by the job.
# It is required to run parallel pods in the job and be able to do simultaneously forget backups in parallel of different PVs.
JOB_UID=$(cat /etc/jobinfo/labels | grep 'job-name' | cut -d'=' -f2 |  tr -d '"')

# Iterates over all the items of the repo queue identified by the job id and the init name.
while true; do
  ITEM=$(redis-cli -h redis LPOP job-$JOB_UID-$REDIS_QUEUE_INIT_NAME-queue)
  if [ -z "$ITEM" ]; then
    echo "No more restic folders to process"
    exit 0
  fi

  # We need to export RESTIC_REPOSITORY to a new path as we now backup each of the PVs
  # separately into a different folder per PV (See https://its.cern.ch/jira/browse/CIPAAS-605)
  export RESTIC_REPOSITORY="${RESTIC_REPO_BASE}/${PV_NAME}"

  # remove any stale lock (e.g. failed backups)
  restic unlock

  # Run restic check to verify that all data is properly stored in the repo.
  if ! restic check; then
    echo "ERROR when checking restic data, it seems the data is not properly stored in the repository"
    exit 1
  fi

  # forget and prune old backups
  # Both forget and prune need the exclusive lock on the whole restic repo in S3 (cannot run concurrently with backups)
  # so we do both operations together
  echo "Forgetting backups..."
  restic forget ${restic_forget_args}

done

echo "No more restic folders to process"
