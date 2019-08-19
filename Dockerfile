FROM gitlab-registry.cern.ch/paas-tools/openshift-client

COPY ./worker.py ./rediswq.py ./enqueue_pvs.sh ./backup_pvs.sh /

RUN yum install epel-release -y && \
    # install redis
    yum install redis -y && \
    # install restic
    yum install yum-plugin-copr -y && \
    yum copr enable copart/restic -y && \
    yum install restic -y && \
    yum clean all

CMD python worker.py
