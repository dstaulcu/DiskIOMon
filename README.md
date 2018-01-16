# DiskIOMon
Identify sources of large file transfers when disk queue lengths are high

Description:
-----------------------------------

   DiskIOMon monitors disk queue lengths using perfmon inexpensive. When thresholds are exceeded multiple times consecutively, xperf is invoked to capture and export a window of disk activity. The export data is then summarized to processes and files contributing to disk demand.

![alt tag](https://github.com/dstaulcu/DiskIOMon/blob/master/Capture.JPG)
