
<#
.Synopsis
   Identify sources of large file transfers when disk queue lengths are high
.DESCRIPTION
   Monitors disk queue lengths using perfmon counters (inexpensive) until thresholds are exceeded multiple times consecutively.
   When conditions are met, invoke ETW tracing (expensive) for desired duration and export results.
   Summarizes exported data to identify processes and files with highest IO.
#>

$xperfpath = "C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe"
$SampleFrequencySeconds = 1      # How many secends should we wait between perfmon counter samples?
$AlertSampleValueThreshold = 2   # Perfmon value which is alert worthy
$AlertRequiredRecurrence = 3     # Count of consecutive perfmon counter threhold alerts required to invoke trace taking action
$TraceCaptureDuration = 5        # duration, in seconds, to capture kernel trace data
$MinTimeBetweenTraces = 60       # Amount of time to wait before gathering any subsequent trace (in seconds)

$csvfile = "$($env:temp)\diskiotrace.csv"
$SampleHistory = @()

function RegisterEventSource {
    $eventSources = @(
    "Application,DiskIOMon"
    )
 
    foreach($logSource in $eventSources) {
        $log = $logSource.split(",")[0]
        $source = $logSource.split(",")[1]
        if ([System.Diagnostics.EventLog]::SourceExists($source) -eq $false) {
            write-host "Creating event source $source on event log $log"
            [System.Diagnostics.EventLog]::CreateEventSource($source, $log)
            write-host -foregroundcolor green "Event source $source created"
        } else {
            write-host -foregroundcolor yellow "Warning: Event source $source already exists. Cannot create this source on Event log $log"
        }
    }
}



function CaptureTrace {
    param($duration=5,$xperfpath,$outputfile)
    $etlfile = "$($env:temp)\diskiotrace.etl"
    $csvfile = "$($env:temp)\diskiotrace.csv"
    if (Test-Path -Path $etlfile) { Remove-Item -Path $etlfile -Force }
    if (Test-Path -Path $csvfile) { Remove-Item -Path $csvfile -Force }

    # Initiate Trace
    write-host (Get-Date) " - Initiating $($duration) second DiskIO trace..."
    & $xperfpath -on PROC_THREAD+LOADER+DISK_IO+DISK_IO_INIT -stackwalk DiskReadInit+DiskWriteInit+DiskFlushInit

    # Let trace run for alotted time
    Start-Sleep -Seconds $duration
    write-host (Get-Date) " - Stopping, exporting, and transforming capture..."
    & $xperfpath -stop -d $etlfile | out-null
    & $xperfpath -i $etlfile -o $csvfile -target machine -a diskio -detail | Out-Null

    # clean up the csv file
    $content = Get-Content -Path $csvfile
    $headers = $content[7] -replace "[\s|`(|`)|`/]",""
    $headers | Set-Content -Path $csvfile
    $records = $content[8..$content.count]
    $records | Add-Content -Path $csvfile

    # objectify the results
    $content = Import-Csv -Path $csvfile
 
    $newcontent = @()
    foreach ($item in $content) {

        $IOSize = [uint32]$item.IOSize
        $ProcessName =  $item.ProcessNamePID.split("(")[0].trim()
        $ProcessID =  ($item.ProcessNamePID.split("(")[1].trim()).replace(")","")

        $CustomEvent = [PSCustomObject]@{
            IOType = ($item.IOType)         #IOType: Read, Write, or Flush
            StartTime = ($item.StartTime)
            EndTime = ($item.EndTime)
            IOTime = ($item.EndTime)
            DiskSrvT = ($item.DiskSrvT)     #Disk Service Time (microseconds): An inferred duration the I/O has spent on the device
            QDI = ($item.QDI)               #Queue Depth at Init (microseconds): Queue depth for that disk, irrespective of partitions, at the time this I/O request initialized
            IOSize = ($IOSize)              #IO Size (bytes): Size of this I/O, in bytes
            ProcessName = $ProcessName
            ProcessID = $ProcessID
            ProcessNameID = ("$($ProcessName):$($ProcessID)")
            Disk = ($item.Disk)
            Filename = ($item.Filename)
        }    
        $newcontent += $CustomEvent
    }

    # Get sorted lists of (1) Sum(IOTime) and (2) Sum(Bytes) by Process and FileName
    $GroupedEvents = $newcontent | Group-Object -Property Disk, ProcessNameID, IOType, Filename
    $Summary = @()
    foreach ($GroupedEvent in $GroupedEvents) {

        $SumIOTime = ($GroupedEvent.Group | Measure-Object -Property IOTime -sum).Sum
        $SumIOSize = ($GroupedEvent.Group | Measure-Object -Property IOSize -sum).Sum
        $IOCount = ($GroupedEvent.Group | Measure-Object).Count

        $CustomEvent = [PSCustomObject]@{
            ProcessNameID = ($GroupedEvent.Group[0].ProcessNameID) 
            ProcessName = ($GroupedEvent.Group[0].ProcessName)
            ProcessId = ($GroupedEvent.Group[0].ProcessID)
            Disk = ($GroupedEvent.Group[0].Disk)
            Filename = ($GroupedEvent.Group[0].Filename)
            IOType = ($GroupedEvent.Group[0].IOType)
            SumIOTime = ($SumIOTime)
            SumIOSizeB = ($SumIOSize)
            IOCount = ($IOCount)
        }  
        $Summary += $CustomEvent
    }

    # Print summary top processes by size of IO
    write-host "`nCapture Summary: (Top 5 disk transfers)`n"
    $Message = $Summary | Sort-Object -Descending -Property SumIOSizeB | Select-Object -First 5 -Property ProcessName, ProcessID, Disk, IOType, FileName, SumIOSizeB, IOCount 
    $Message

    # Write the the events into the message field of event log
    $Message = $Message | ConvertTo-Json
    $LogName = "Application"
    $SourceName = "DiskIOMon"
    Write-EventLog -LogName $LogName -Source $SourceName -EventId 1 -EntryType Information -Message $Message.ToString()


    if (Test-Path -Path $etlfile) { Remove-Item -Path $etlfile -Force }
}

#verify xperf is accessible
if (!(Test-Path -Path $xperfpath)) {
    write-host "Invalid path to xperf, exiting."
    exit
}

#verify we are running with admin priv.
$myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent();
$myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID);

# Get the security principal for the administrator role
$adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator;

# Check to see if we are currently running as an administrator
if (!($myWindowsPrincipal.IsInRole($adminRole)))
{
    write-host "This script needs to run as admin to invoke ETW data collection using Xperf. Exiting."
    exit
}

RegisterEventSource

write-host (get-date) " - Monitoring disk queue lengths."

$LastTraceTime = Out-Null
# Loop forever
while($true)
{
    # collect sample data from across all disks and add to sample history object
    $Sample = Get-Counter -Counter '\LogicalDisk(*)\Current Disk Queue Length' -SampleInterval 1 -MaxSamples 1
    $SampleDateTime = $Sample.Timestamp
    $CounterSamples = $Sample.CounterSamples
    $CounterSamples = $CounterSamples | ?{$_.InstanceName -ne "_total"}
    foreach ($CounterSample in $CounterSamples) {

        if ($CounterSample.CookedValue -ge $AlertSampleValueThreshold) { $CookedValueStatus = "WARN" } else { $CookedValueStatus = "OK" }

        $CustomEvent = [PSCustomObject]@{
            SampleDateTime = $SampleDateTime
            InstanceName = $CounterSample.InstanceName
            CookedValue = $CounterSample.CookedValue
            Status = $CookedValueStatus
        }  
        $SampleHistory += $CustomEvent

    }   
    
    # Trim sample history object to only include up to $AlertRequiredRecurrence most recent samples of each distinct instance
    $SampleHistoryGroups = $SampleHistory | Group-Object -Property InstanceName
    $SampleHistory = @()
    foreach ($SampleHistoryGroup in $SampleHistoryGroups)  {
        $SampleHistory += $SampleHistoryGroup | Select-Object -ExpandProperty Group | Sort-Object -Property SampleDateTime -Descending | Select-Object -First $AlertRequiredRecurrence
    }
    $SampleHistory = $SampleHistory | Sort-Object -Property InstanceName, SampleDateTime -Descending

    # Select out instances which have 3 samples and are thus qualified for action if alert thresholds met.
    $SampleHistoryQualified = $SampleHistory | Group-Object -Property InstanceName | ?{$_.Count -eq $AlertRequiredRecurrence} | %{$_ | Select-Object -ExpandProperty Group}

    # Create object having instances of drives and their count of alerts
    $SampleHistoryQualifiedGroup = $SampleHistoryQualified | Group-Object -Property InstanceName 
    $SampleHistoryQualifiedStatus = $SampleHistoryQualifiedGroup | %{[pscustomobject]@{InstanceName=$_.Name;AlertCount=(($_.Group | ?{$_.Status -eq 'WARN'} | Group-Object -Property Status).Count)}}

    # print out message when any instance exeeds threshold in all samples
    foreach ($SampleHistoryQualifiedStatusItem in $SampleHistoryQualifiedStatus) {
        if ($SampleHistoryQualifiedStatusItem.AlertCount -eq $AlertRequiredRecurrence) {
            write-host (get-date) " - LogicalDisk [$($SampleHistoryQualifiedStatusItem.InstanceName)] has exceeded [$($AlertRequiredRecurrence)] consecutive alert thresholds."

            if ($LastTraceTime) {
                $LastTraceTimeSecondsAgo = [math]::round((New-TimeSpan -Start $LastTraceTime -End (Get-Date)).TotalSeconds,1)
                write-host (get-date) " - Last trace was [$($LastTraceTimeSecondsAgo)] second(s) ago."
            }

            if (($LastTraceTime) -and ($LastTraceTimeSecondsAgo -le $MinTimeBetweenTraces)) {
                write-host (get-date) " - Last trace was too recent, skipping."
            } else {
                $LastTraceTime = (get-date)
                CaptureTrace -duration $TraceCaptureDuration -xperfpath $xperfpath -outputfile $csvfile
            }
           
        }
    } 

    Start-Sleep -Seconds $SampleFrequencySeconds
}
