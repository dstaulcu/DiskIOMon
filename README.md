# DiskIOMon
Identify sources of large file transfers when disk queue lengths are high

Description:
-----------------------------------

   Monitors disk queue lengths using perfmon counters (inexpensive) until thresholds are exceeded multiple times consecutively.
   When conditions are met, invoke ETW tracing (relatively expensive) for desired duration and export results.
   Transforms and summarizes exported data to identify processes and files contributing to highest IO.

![alt tag](https://github.com/dstaulcu/DiskIOMon/blob/master/Capture.JPG)
