# Backup solution for CephFS persistent volumes

We need to backup CephFS persistent volumes. By default we do not have any automatically backup solution.

This [backup solution](https://gitlab.cern.ch/paas-tools/storage/backup-cephfs-volumes) backs up the CephFS persistent volumes.
A combination of [StorageClass annotations](https://gitlab.cern.ch/paas-tools/infrastructure/cephfs-csi-deployment/blob/master/chart/templates/cephfs-storageclass.yaml)
and 
[OPA rules](https://gitlab.cern.ch/paas-tools/infrastructure/openpolicyagent/merge_requests/4) sets
the label `backup-cephfs-volumes.cern.ch/backup=true` on PVs to be backed up.
When the backup job starts, it creates several pods based on the job's `.spec.parallelism`. Their first operation is to add a `json` document describing each PV to be backed up
to a `redis` queue. This is done for all PVs that match this label.
Only one of the backup pods performs the queueing operation in its `initContainer`.

Then all the backups pods work in parallel in their main container. One by one, they de-queue each PV's `json` details and mount the PV locally (this requires the pods to run `privileged`). Once mount succeeds,
the pod backs up the PV using [`restic`](https://restic.net/). Then it unmounts it and moves on to the next PV.

Once this PV is backed up, we add some annotations into the PV to indicate whether it succeeded or it failed to back up the PV.

Brief summary:

- The PVs are backed up using S3
- The persistent volumes are going to be backed up once a day
- The back ups are going to be pruned once a week, following the resticForgetArgs specified in the values of
[CephFS csi deployment](https://gitlab.cern.ch/paas-tools/infrastructure/cephfs-csi-deployment).

## ServiceAccounts

- Service account where the `cronjob` is running. In this case we define the service account in [CephFS deployment](https://gitlab.cern.ch/paas-tools/infrastructure/cephfs-csi-deployment).
  This service account must be privileged to be able to mount volumes inside the pods created by the cronjob.

## Deployment

This backup solution for CephFS volumes is deployed with `helm` as a subchart of [CephFS csi deployment](https://gitlab.cern.ch/paas-tools/infrastructure/cephfs-csi-deployment).
The namespace used to be deployed is by default `paas-infra-cephfs`, in all the clusters.
