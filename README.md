# README

## Create project
oc create project test-backups

## Lunch Redis
oc create -f redis-pod.yaml
oc create -f redis-service.yaml

## Add the clusterrole rbac
oc create -f backup-cephfs-rbac.yaml

## Add the scc privileghed to the account in order to mount and umount pvs into the pods
oc adm policy add-scc-to-user privileged system:serviceaccount:test-backups:backup-cephfs-job -n test-backups