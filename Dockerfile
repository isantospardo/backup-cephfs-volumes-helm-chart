FROM gitlab-registry.cern.ch/paas-tools/openshift-client

ARG restic_version=0.10.0

COPY ./enqueue_pvs.sh ./backup_pvs.sh ./forget_backup_pvs.sh /

RUN yum install epel-release -y && \
    # install redis
    yum install redis -y && \
    # install restic
    yum install yum-plugin-copr -y && \
    yum copr enable copart/restic -y && \
    yum install restic-${restic_version} -y && \
    # install s3cmd for backup recovery
    yum install s3cmd -y && \
    # we need this to interact with manila OpenStack to get CephFS information
    yum install centos-release-openstack-stein -y && \
    yum install -y /usr/bin/{nova,cinder,openstack} --disableplugin=protectbase && \
    yum clean all
