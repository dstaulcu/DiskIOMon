﻿
<#
.Synopsis
   Identify sources of large file transfers when disk queue lengths are high
.DESCRIPTION
   Monitors disk queue lengths using perfmon counters (inexpensive) until thresholds are exceeded multiple times consecutively.
   When conditions are met, invoke ETW tracing (expensive) for desired duration and export results.
   Summarizes exported data to identify processes and files with highest IO.
#>

$xperfpath = "C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe"
$SampleFrequencySeconds = 1      # How many seconds to wait between perfmon counter samples?
$AlertSampleValueThreshold = 2   # Perfmon couter sample value which is alert worthy
$AlertRequiredRecurrence = 3     # Count of consecutive alerts required to invoke trace taking action
$TraceCaptureDuration = 5        # Duration, in seconds, to capture kernel trace data
$MinTimeBetweenTraces = 300      # Amount of time to wait before gathering any subsequent trace (in seconds)
$LogName = "Application"         # The event log to which summary data is written
$SourceName = "DiskIOMon"        # The source name within the event log to which summary data is written

$OrigVerbosePreference = $VerbosePreference ; $VerbosePreference = "Continue"
$OrigDebugPreference = $DebugPreference # ; $DebugPreference = "Continue"

function CaptureData {
    
    param($duration=5,$xperfpath)

    $etlfile = "$($env:temp)\diskiotrace.etl"
    $csvfile = "$($env:temp)\diskiotrace.csv"
    if (Test-Path -Path $etlfile) { Remove-Item -Path $etlfile -Force }
    if (Test-Path -Path $csvfile) { Remove-Item -Path $csvfile -Force }

    # Initiate Trace
    Write-Verbose -Message "$(Get-Date) - Initiating $($duration) second trace..."
    & $xperfpath -on PROC_THREAD+LOADER+DISK_IO+DISK_IO_INIT -stackwalk DiskReadInit+DiskWriteInit+DiskFlushInit

    # Let trace run for alotted time
    Start-Sleep -Seconds $duration

    # Stop trace and export
    Write-Verbose -Message "$(Get-Date) - Stopping, exporting, and transforming trace data..."
    & $xperfpath -stop -d $etlfile | out-null
    & $xperfpath -i $etlfile -o $csvfile -target machine -a diskio -detail | Out-Null

    # clean up the csv file
    $CapturedData = Get-Content -Path $csvfile
    $headers = $CapturedData[7] -replace "[\s|`(|`)|`/]",""
    $headers | Set-Content -Path $csvfile
    $records = $CapturedData[8..$CapturedData.count]
    $records | Add-Content -Path $csvfile

    # objectify the results
    $CapturedData = Import-Csv -Path $csvfile

    if (Test-Path -Path $etlfile) { Remove-Item -Path $etlfile -Force }
    if (Test-Path -Path $csvfile) { Remove-Item -Path $csvfile -Force }

    return $CapturedData
}
function PrepareData {
    param($dataset)

    $PreparedData = @()
    foreach ($item in $dataset) {

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
        $PreparedData += $CustomEvent
    }

    return $PreparedData
  
} 
function ReportData-DiskIO-ByDiskProcessIOTypeFileName {

    param($dataset)

    # Get sorted lists of (1) Sum(IOTime) and (2) Sum(Bytes) by Process and FileName
    $GroupedEvents = $dataset | Group-Object -Property Disk, ProcessNameID, IOType, Filename
    $SummaryData = @()

    foreach ($GroupedEvent in $GroupedEvents) {

        $SumIOTime = ($GroupedEvent.Group | Measure-Object -Property IOTime -sum).Sum
        $SumIOSize = ($GroupedEvent.Group | Measure-Object -Property IOSize -sum).Sum
        $IOCount = ($GroupedEvent.Group | Measure-Object).Count

        $CustomEvent = [PSCustomObject]@{
            ProcessNameID = ($GroupedEvent.Group[0].ProcessNameID) 
            ProcessName = ($GroupedEvent.Group[0].ProcessName)
            ProcessID = ($GroupedEvent.Group[0].ProcessID)
            Disk = ($GroupedEvent.Group[0].Disk)
            FileName = ($GroupedEvent.Group[0].Filename)
            IOType = ($GroupedEvent.Group[0].IOType)
            SumIOTime = ($SumIOTime)
            SumIOSizeB = ($SumIOSize)
            IOCount = ($IOCount)
        }  
        $SummaryData += $CustomEvent
    }

    # Print summary top processes by size of IO
    $report = $SummaryData | Sort-Object -Descending -Property SumIOSizeB | Select-Object -First 5 -Property ProcessName, ProcessID, Disk, IOType, FileName, SumIOSizeB, IOCount
    $report = [string]($report | ConvertTo-Json)
    Write-EventLog -LogName $LogName -Source $SourceName -EventId 10 -EntryType Information -Message $report
}
function ReportData-DiskIO-ByDiskProcessIOType {
    
        param($dataset)
    
        # Get sorted lists of (1) Sum(IOTime) and (2) Sum(Bytes) by Process and FileName
        $GroupedEvents = $dataset | Group-Object -Property Disk, ProcessNameID, IOType
        $SummaryData = @()
    
        foreach ($GroupedEvent in $GroupedEvents) {
    
            $SumIOTime = ($GroupedEvent.Group | Measure-Object -Property IOTime -sum).Sum
            $SumIOSize = ($GroupedEvent.Group | Measure-Object -Property IOSize -sum).Sum
            $IOCount = ($GroupedEvent.Group | Measure-Object).Count      
    
            $CustomEvent = [PSCustomObject]@{
                ProcessNameID = ($GroupedEvent.Group[0].ProcessNameID) 
                ProcessName = ($GroupedEvent.Group[0].ProcessName)
                ProcessID = ($GroupedEvent.Group[0].ProcessID)
                Disk = ($GroupedEvent.Group[0].Disk)
                IOType = ($GroupedEvent.Group[0].IOType)
                SumIOTime = ($SumIOTime)
                SumIOSizeB = ($SumIOSize)
                IOCount = ($IOCount)
            }  
            $SummaryData += $CustomEvent
        }
    
        $report = $SummaryData | Sort-Object -Descending -Property SumIOSizeB | Select-Object -First 5 -Property ProcessName, ProcessID, Disk, IOType, SumIOSizeB, IOCount
        $report = [string]($report | ConvertTo-Json)
        Write-EventLog -LogName $LogName -Source $SourceName -EventId 11 -EntryType Information -Message $report
    }
function RegisterEventSource {
    param($logname,$SourceName)
    if ([System.Diagnostics.EventLog]::SourceExists($sourcename) -eq $false) {
        Write-Verbose -Message "Creating event source $($sourcename) on event log $logname"
        [System.Diagnostics.EventLog]::CreateEventSource($sourcename, $logname)
        write-verbose -Message "Event source $($sourcename) created"
    }
}
function CheckDependencies {

    # verify xperf is accessible
    if (!(Test-Path -Path $xperfpath)) {
        write-host "Invalid path to xperf, exiting."
        exit
    }

    # verify we are running with admin priv.
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

    RegisterEventSource -logname $logname -sourcename $SourceName

}
function Get-SampleInfo {
    param($sample)

    $SampleDateTime = $Sample.Timestamp
    $CounterSamples = $Sample.CounterSamples
    $CounterSamples = $CounterSamples | where-object {$_.InstanceName -ne "_total"}
    $sampleInfo = @()

    foreach ($CounterSample in $CounterSamples) {

        if ($CounterSample.CookedValue -ge $AlertSampleValueThreshold) { $CookedValueStatus = "WARN" } else { $CookedValueStatus = "OK" }

        $SampleData = [PSCustomObject]@{
            SampleDateTime = $SampleDateTime
            InstanceName = $CounterSample.InstanceName
            CookedValue = $CounterSample.CookedValue
            Status = $CookedValueStatus
        }  
        $sampleInfo += $SampleData
    
    }
    return $SampleInfo
}
function Update-SampleHistory {
    param($SampleHistory,$SampleInfo)

    $SampleHistory += $SampleInfo   
    
    # Trim sample history object to only include up to $AlertRequiredRecurrence most recent samples of each distinct instance
    $SampleHistoryGroups = $SampleHistory | Group-Object -Property InstanceName
    $SampleHistory = @()
    foreach ($SampleHistoryGroup in $SampleHistoryGroups)  {
        $SampleHistory += $SampleHistoryGroup | Select-Object -ExpandProperty Group | Sort-Object -Property SampleDateTime -Descending | Select-Object -First $AlertRequiredRecurrence
    }
    $SampleHistory = $SampleHistory | Sort-Object -Property InstanceName, SampleDateTime -Descending
       
    return $SampleHistory
}
function Get-SampleHistoryStatus {
    param($SampleHistory)

    # Select out instances which have 3 samples and are thus qualified for action if alert thresholds met.
    $SampleHistoryQualified = $SampleHistory | Group-Object -Property InstanceName | Where-Object{$_.Count -eq $AlertRequiredRecurrence} | ForEach-Object {$_ | Select-Object -ExpandProperty Group}
    
    # Create object having instances of drives and their count of alerts
    $SampleHistoryQualifiedGroup = $SampleHistoryQualified | Group-Object -Property InstanceName 
    $SampleHistoryStatus = $SampleHistoryQualifiedGroup | ForEach-Object {[pscustomobject]@{InstanceName=$_.Name;AlertCount=(($_.Group | Where-object {$_.Status -eq 'WARN'} | Group-Object -Property Status).Count)}}

    return $SampleHistoryStatus
}
function Get-DriveInfo {
    
    $DriveInfo = Get-WmiObject Win32_DiskDrive | ForEach-Object {
        $disk = $_
        $partitions = "ASSOCIATORS OF " +
                    "{Win32_DiskDrive.DeviceID='$($disk.DeviceID)'} " +
                    "WHERE AssocClass = Win32_DiskDriveToDiskPartition"
        Get-WmiObject -Query $partitions | ForEach-Object {
            $partition = $_
            $drives = "ASSOCIATORS OF " +
                        "{Win32_DiskPartition.DeviceID='$($partition.DeviceID)'} " +
                        "WHERE AssocClass = Win32_LogicalDiskToPartition"
            Get-WmiObject -Query $drives | ForEach-Object {
                New-Object -Type PSCustomObject -Property @{
                Disk        = $disk.DeviceID
                DiskSize    = $disk.Size
                DiskModel   = $disk.Model
                DiskInterface = $disk.InterfaceType
                Partition   = $partition.Name
                RawSize     = $partition.Size
                DriveLetter = $_.DeviceID
                VolumeName  = $_.VolumeName
                Size        = $_.Size
                FreeSpace   = $_.FreeSpace
                }
            }
        }
    }

    $DriveList = @()
    foreach ($Drive in $DriveInfo) {
        $CustomEvent = [PSCustomObject]@{
            DiskModel   = $Drive.DiskModel
            DiskInterface = $Drive.DiskInterface
            Partition   = $Drive.Partition
            DriveLetter = $Drive.DriveLetter    
            Disk = ([regex]"Disk\s+#(\d+),").match($Drive.Partition).Groups[1].value
        }    
        $DriveList += $CustomEvent    
    }
    #$DriveList = [string]($DriveList | ConvertTo-Json)    
    return $DriveList
}

# check program dependences (for xperf, admin priv, and registered event source)
CheckDependencies 

$LastTraceTime = Out-Null
write-verbose -Message "$(get-date) - Monitoring disk queue lengths."
while($true)
{
    # collect sample data from across all disks and add to sample history object
    $Sample = Get-Counter -Counter '\LogicalDisk(*)\Current Disk Queue Length' -SampleInterval 1 -MaxSamples 1
    $SampleInfo = Get-SampleInfo -sample $Sample
    $SampleHistory = Update-SampleHistory -SampleHistory $SampleHistory -SampleInfo $SampleInfo
    $SampleHistoryStatus = Get-SampleHistoryStatus -SampleHistory $SampleHistory

    # print out message when any instance exeeds threshold in all samples
    foreach ($SampleHistoryItem in $SampleHistoryStatus) {
        if ($SampleHistoryItem.AlertCount -eq $AlertRequiredRecurrence) {
            $SampleDuration = [math]::round($AlertRequiredRecurrence * $SampleFrequencySeconds,0)

            $DriveInfo = Get-DriveInfo            
            $DriveInfo = $DriveInfo | Where-Object {$_.DriveLetter -eq $SampleHistoryItem.InstanceName}
            $Disk = $DriveInfo | Select-Object -ExpandProperty Disk
            $DiskModel = $DriveInfo | Select-Object -ExpandProperty DiskModel
            $DiskInterface = $DriveInfo | Select-Object -ExpandProperty DiskInterface                                
            
            $AlertMessage = "LogicalDisk [$($SampleHistoryItem.InstanceName)] on disk [$($Disk)] having model [$($DiskModel)] interfacing over [$($DiskInterface)] had queue length  >= $($AlertSampleValueThreshold)ms in each sample over the last $($SampleDuration) seconds."
            Write-EventLog -LogName $LogName -Source $SourceName -EventId 1 -EntryType Information -Message $AlertMessage
            Write-Verbose -Message "$(get-date) - $($AlertMessage)"

            if ($LastTraceTime) {
                $LastTraceTimeSecondsAgo = [math]::round((New-TimeSpan -Start $LastTraceTime -End (Get-Date)).TotalSeconds,1)
                write-verbose -Message "$(get-date) - Last trace summary completed [$($LastTraceTimeSecondsAgo)] second(s) ago."
            }

            if (($LastTraceTime) -and ($LastTraceTimeSecondsAgo -le $MinTimeBetweenTraces)) {
                write-verbose "$(get-date) - Last trace was too recent, skipping."
            } else {

                $CapturedData = CaptureData -duration $TraceCaptureDuration -xperfpath $xperfpath
                $PreparedData = PrepareData -dataset $CapturedData

                Write-Verbose -Message "$(get-date) - Posting reports to windows event log $($logname) using sourcename $($sourcename)."                
                ReportData-DiskIO-ByDiskProcessIOTypeFileName -dataset $PreparedData
                ReportData-DiskIO-ByDiskProcessIOType -dataset $PreparedData

                $LastTraceTime = (get-date)          
                $SampleHistory = @() # reset counters

                Write-Verbose -Message "$(get-date) - Returning to monitor mode."                                
            }
           
        }
    } 

    Start-Sleep -Seconds $SampleFrequencySeconds
}

$VerbosePreference = $OrigVerbosePreference
$DebugPreference = $OrigDebugPreference