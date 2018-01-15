
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
$LastTraceTime = Out-Null

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
    write-host (Get-Date) " - Stopping capture..."

    # Export stop trace
    & $xperfpath -stop -d $etlfile | out-null

    write-host (Get-Date) " - Transforming trace data..."
    & $xperfpath -i $etlfile -o $csvfile -target machine -a diskio -detail 

    # strip the first few lines from the output file
    $content = Get-Content -Path $csvfile

    # create the header row with simplified column names
    $headers = $content[7] -replace "[\s|`(|`)|`/]",""
    $headers | Set-Content -Path $csvfile
    $records = $content[8..$content.count]
    $records | Add-Content -Path $csvfile
    $content = Import-Csv -Path $csvfile

    # convert values
    # Great ref: https://blogs.technet.microsoft.com/robertsmith/2012/02/07/analyzing-storage-performance-using-the-windows-performance-analysis-toolkit-wpt
    $newcontent = @()
    foreach ($item in $content) {
        $CustomEvent = New-Object -TypeName PSObject

        #IOType: Read, Write, or Flush
        $CustomEvent | Add-member -Type NoteProperty -Name 'IOType' -Value ($item.IOType)
        #Complete Time (Milliseconds):  Time of I/O completion, relative to start and stop of the current trace. (not clock time and not overall I/O completion time)
        $CustomEvent | Add-member -Type NoteProperty -Name 'StartTime' -Value ($item.StartTime)
        $CustomEvent | Add-member -Type NoteProperty -Name 'EndTime' -Value ($item.EndTime)
        #IO Time (Microseconds): Amount of time the I/O took to complete, based on timestamps in the IRP header for creation and when the IRP is completed.  
        $CustomEvent | Add-member -Type NoteProperty -Name 'IOTime' -Value ($item.IOTime)
        #Disk Service Time (microseconds): An inferred duration the I/O has spent on the device
        $CustomEvent | Add-member -Type NoteProperty -Name 'DiskSrvT' -Value ($item.DiskSrvT) 
        #Queue Depth at Init (microseconds): Queue depth for that disk, irrespective of partitions, at the time this I/O request initialized
        $CustomEvent | Add-member -Type NoteProperty -Name 'QDI' -Value ($item.QDI) 
        #IO Size (bytes): Size of this I/O, in bytes
        $IOSize = [uint32]$item.IOSize
        $CustomEvent | Add-member -Type NoteProperty -Name 'IOSize' -Value ($IOSize)

        $ProcessName =  $item.ProcessNamePID.split("(")[0].trim()
        $CustomEvent | Add-member -Type NoteProperty -Name 'ProcessName' -Value $ProcessName

        $ProcessID =  ($item.ProcessNamePID.split("(")[1].trim()).replace(")","")
        $CustomEvent | Add-member -Type NoteProperty -Name 'ProcessID' -Value $ProcessID

        $CustomEvent | Add-member -Type NoteProperty -Name 'ProcessNameID' -Value ("$($ProcessName):$($ProcessID)")

        $CustomEvent | Add-member -Type NoteProperty -Name 'Disk' -Value ($item.Disk)
        $CustomEvent | Add-member -Type NoteProperty -Name 'Filename' -Value ($item.Filename)
        $newcontent += $CustomEvent       
    }

    # Get sorted lists of (1) Sum(IOTime) and (2) Sum(Bytes) by Process and FileName
    $GroupedEvents = $newcontent | Group-Object -Property Disk, ProcessNameID, IOType, Filename
    $Summary = @()
    foreach ($GroupedEvent in $GroupedEvents) {
        $CustomEvent = New-Object -TypeName PSObject  
        $CustomEvent | Add-Member -Type NoteProperty -Name "ProcessNameID" -Value ($GroupedEvent.Group[0].ProcessNameID)       
        $CustomEvent | Add-Member -Type NoteProperty -Name "ProcessName" -Value ($GroupedEvent.Group[0].ProcessName)
        $CustomEvent | Add-Member -Type NoteProperty -Name "ProcessId" -Value ($GroupedEvent.Group[0].ProcessID)
        $CustomEvent | Add-Member -Type NoteProperty -Name "Disk" -Value ($GroupedEvent.Group[0].Disk)
        $CustomEvent | Add-Member -Type NoteProperty -Name "Filename" -Value ($GroupedEvent.Group[0].Filename)
        $CustomEvent | Add-Member -Type NoteProperty -Name "IOType" -Value ($GroupedEvent.Group[0].IOType)
        

        $SumIOTime = ($GroupedEvent.Group | Measure-Object -Property IOTime -sum).Sum
        $CustomEvent | Add-Member -Type NoteProperty -Name "SumIOTime" -Value $SumIOTime

        $SumIOSize = ($GroupedEvent.Group | Measure-Object -Property IOSize -sum).Sum
        $CustomEvent | Add-Member -Type NoteProperty -Name "SumIOSizeB" -Value ([math]::round(($SumIOSize)))

        $IOCount = ($GroupedEvent.Group | Measure-Object).Count
        $CustomEvent | Add-Member -Type NoteProperty -Name "IOCount" -Value $IOCount

        $Summary += $CustomEvent
    }

    # Print summary top processes by size of IO
    write-host "`nTrace Collection Summary (Top 5 transfers)`n"
    $Summary | Sort-Object -Descending -Property SumIOSizeB | Select-Object -First 5 -Property ProcessName, ProcessID, Disk, IOType, FileName, SumIOSizeB, IOCount | Format-Table
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


# Loop forever
while($true)
{
    # collect sample data from across all disks and add to sample history object
    $Sample = Get-Counter -Counter '\LogicalDisk(*)\Current Disk Queue Length' -SampleInterval 1 -MaxSamples 1
    $SampleDateTime = $Sample.Timestamp
    $CounterSamples = $Sample.CounterSamples
    $CounterSamples = $CounterSamples | ?{$_.InstanceName -ne "_total"}
    foreach ($CounterSample in $CounterSamples) {
        $CustomEvent = New-Object -TypeName PSObject
        $CustomEvent | Add-member -Type NoteProperty -Name 'SampleDateTime' -Value $SampleDateTime
        $CustomEvent | Add-member -Type NoteProperty -Name 'InstanceName' -Value $CounterSample.InstanceName
        $CustomEvent | Add-member -Type NoteProperty -Name 'CookedValue' -Value $CounterSample.CookedValue
        # provide a status value based on whether observed value met or exceeded defined threshold
        if ($CounterSample.CookedValue -ge $AlertSampleValueThreshold) { $CookedValueStatus = "WARN" } else { $CookedValueStatus = "OK" }
        $CustomEvent | Add-member -Type NoteProperty -Name 'Status' -Value $CookedValueStatus
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
            write-host (get-date) " - LogicalDisk [$($SampleHistoryQualifiedStatusItem.InstanceName)] has exceeded disk queue length alert thresholds."

            if (($LastTraceTime) -and ((New-TimeSpan -Start $LastTraceTime -End (Get-Date)).Seconds -lt $MinTimeBetweenTraces)) {
                write-host (get-date) " - Last trace session was less than $($MinTimeBetweenTraces) seconds ago, skipping trace."
                continue
            }
            
            $LastTraceTime = (get-date)
            CaptureTrace -duration $TraceCaptureDuration -xperfpath $xperfpath -outputfile $csvfile
           
        }
    } 

    Start-Sleep -Seconds $SampleFrequencySeconds
}
