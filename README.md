# README

## Prerequisites
Some preparation steps need to be performed with cluster-admin permissions.
This needs to be done only once per OpenShift cluster/environment.

The rest of the deployment will be handled by GitLab CI.
We need to create 2 [GitLab CI variables](https://docs.gitlab.com/ee/ci/variables/#via-the-ui) in this project
for each OpenShift environment:
1. S3 and restic variables: the information can be founded in [here](https://openshiftdocs.web.cern.ch/openshiftdocs/Deployment/CephFSVolumeBackupWithRestic.md)

TODO: move to csi-deployment
# Create secret for cephs backups s3
oc create -f cephfs-backup-secret.yaml

## Deploy Redis
oc create -f redis-pod.yaml
oc create -f redis-service.yaml

### Add the clusterrole rbac
oc create -f backup-cephfs-rbac.yaml

### Add the scc privileghed to the account in order to mount and umount pvs into the pods
oc adm policy add-scc-to-user privileged system:serviceaccount:test-backups:backup-cephfs-job -n test-backups
