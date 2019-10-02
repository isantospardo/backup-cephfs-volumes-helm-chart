#!/usr/bin/env python

import time
import rediswq

host="redis"

q = rediswq.RedisWQ(name="job2", host="redis")
print("Worker with sessionID: " +  q.sessionID())
print("Initial queue state: empty=" + str(q.empty()))

# load queue with PV json
while not q.empty():
  item = q.lease(lease_secs=10, block=True, timeout=2)
  if item is not None:
    itemstr = item.decode("utf=8")
    print("Working on " + itemstr)
    time.sleep(10)
    q.complete(item)
  else:
    print("Waiting for work")
print("Queue empty, exiting")
