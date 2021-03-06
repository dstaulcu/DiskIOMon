# DiskIOMon
Identify sources of large file transfers when disk queue lengths are high.

Description:
-----------------------------------

   DiskIOMon monitors disk queue lengths using perfmon counters. When defined thresholds are exceeded, xperf is invoked to capture disk activity for a brief period of time. Finally, export data is summarized to list top processes and files contributing to disk demand. 

![alt tag](https://github.com/dstaulcu/DiskIOMon/blob/master/screenshots/capture1.jpg)
![alt tag](https://github.com/dstaulcu/DiskIOMon/blob/master/screenshots/capture2.jpg)
![alt tag](https://github.com/dstaulcu/DiskIOMon/blob/master/screenshots/capture3.jpg)
![alt tag](https://github.com/dstaulcu/DiskIOMon/blob/master/screenshots/capture4.jpg)


