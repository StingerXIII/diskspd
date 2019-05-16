<#
DISKSPD - VM Fleet

Copyright(c) Microsoft Corporation
All rights reserved.

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED *AS IS*, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
#>

param(
    $SampleInterval = 3,
    [ValidateSet("CSV FS","SSB Cache","SBL","S2D BW","Hyper-V LCPU","SMB SRV","*")]
    [string[]] $sets = "CSV FS",
    $log = $null
)

if ($log -ne $null) {
    del -Force $log -ErrorAction SilentlyContinue
}

function write-log(
    [string[]] $str
    )
{
    if ($log -ne $null) {
        $str |% {
            "$(get-date) $_" | Out-File -Append -FilePath $log -Width 9999 -Encoding ascii
        }
    }
}

# display name
# ctr name
# display order
# format string
# scalar multiplier

class CounterColumn {

    [string] $displayname
    [string] $setname
    [string[]] $ctrname
    [int] $width
    [string] $fmt
    [decimal] $multiplier
    [ValidateSet("Average","AverageAggregate","Sum")][string] $aggregate
    [boolean] $divider

    CounterColumn(
        [string] $displayname,
        [string] $setname,
        [string[]] $ctrname,
        [int] $width,
        [string] $fmt,
        [decimal] $multiplier,
        [string] $aggregate,
        [boolean] $divider
    )
    {
        $this.displayname = $displayname
        $this.setname = $setname
        $this.ctrname = $ctrname
        $this.width = $width
        $this.fmt = $fmt
        $this.multiplier = $multiplier
        $this.aggregate = $aggregate
        $this.divider = $divider

        if ($this.width -lt $this.displayname.length + 1) {
            $this.width = $this.displayname.length + 1
        }
    }
}

class CounterColumnSet {

    [CounterColumn[]] $columns
    [string[]] $counters
    [string] $topfmt
    [string] $linfmt
    [string] $name

    [string] $totalline
    [string[]] $nodelines

    CounterColumnSet($name)
    {
        $this.columns = $null
        $this.name = $name
    }

    [void] Add([CounterColumn] $c)
    {
        $this.columns += $c
    }

    [void] Seal()
    {
        # assemble the top-line fmt and per-line fmt strings
        # top-line is just strings/width
        # per-line adds the (likely numeric) format specifier
        $n = 1
        $this.topfmt = $this.linfmt = "{0,-16}"
        foreach ($col in $this.columns) {
            $str = ''
            if ($col.divider) {
                $str += '| '
            }
            $str += "{$n,-$($col.width)"
            $this.topfmt += "$str}"
            $this.linfmt += "$($str):$($col.fmt)}"

            $n += 1
        }

        # assemble the list of counter instances that will be needed
        # note that some may be internally aggregated (i.e., total = read + write)
        # in cases where a counterset does not provide an explicit total
        $this.counters = ($this.columns |% {
            $s = $_.setname
            $_.ctrname |% { "\$($s)(_Total)\$($_)" }
        } | group -NoElement).Name
    }

    [void] DisplayPre(
        [hashtable] $samples,
        [hashtable] $psamples
        )
    {
        # aggregate each column across all live sampled nodes
        $this.totalline =  $this.linfmt -f $(
            "Total"
            foreach ($col in $this.columns) {

                # average aggreate doesn't work across nodes if the base is not consistent
                # for instance: cannot average latency safely, but can average cpu utilization
                if ($col.aggregate -ne 'Average' -or $col.aggregate -eq 'AverageAggregate') {
                    $(foreach ($node in $psamples.keys) {
                        get-samples $psamples $node $col
                    }) | get-aggregate $col
                } else {
                    $null
                }
            }
        )

        # individual nodes
        # flags downed/non-responsive nodes by noting which are not
        # present in the processed samples
        $this.nodelines = foreach ($node in $samples.keys | sort) {
            if ($psamples.ContainsKey($node)) {
                $this.linfmt -f $(
                    $node
                    foreach ($col in $this.columns) {
                        $s = get-samples $psamples $node $col
                        if ($s -ne $null) {
                            $a = $s | get-aggregate $col
                            $a
                        } else {
                            "-"
                        }
                    }
                )
            } else {
                $this.topfmt -f $(
                    $node
                    0..($this.columns.count - 1) |% { "-" }
                )
            }
        }
    }

    [void] Display()
    {
        write-host ($this.topfmt -f (,$this.name + $this.columns.displayname))
        write-host -fore green $this.totalline
        $this.nodelines |% { write-host $_ }
    }
}

function get-aggregate(
    [CounterColumn] $col
    )
{
    BEGIN {
        $n = 0
        $v = 0
    }
    PROCESS {
        $n += 1
        $v += $_
    }
    END {
        if ($n -gt 0) {
            switch -wildcard ($col.aggregate) {
                'Sum' {
                    #write-host $col.displayname $col.multipler $v
                    $col.multiplier * $v
                }
                'Average*' {
                    #write-host $col.displayname $col.multiplier $v $n
                    $col.multiplier * $v / $n
                }
            }
        } else {
            $null
        }
    }
}

# get samples out of per-node hash of ctr hashes
function get-samples(
    [hashtable] $h,
    [string] $node,
    [CounterColumn] $col
    )
{
    foreach ($i in $col.ctrname) {

        $k = "$($col.setname)+$($i)"

        if ($h.ContainsKey($node)) {
            if ($h[$node].ContainsKey($k)) {
                $h[$node][$k]
            } else {
                write-log "missing $node[$k] : $($h[$node].Keys.Count) total keys"
            }
        } else {
            write-log "missing $node"
        }
    }
}

$allctrs = @()

###
$c = [CounterColumnSet]::new("CSV FS")
$c.Add([CounterColumn]::new("IOPS", "PhysicalDisk", @("Disk Reads/sec","Disk Writes/sec"), 12, '#,#', 1, 'Sum', $false))
$c.Add([CounterColumn]::new("Reads", "PhysicalDisk", @("Disk Reads/sec"), 12, '#,#', 1, 'Sum',  $false))
$c.Add([CounterColumn]::new("Writes", "PhysicalDisk", @("Disk Writes/sec"), 12, '#,#', 1, 'Sum',  $false))

$c.Add([CounterColumn]::new("BW (MB/s)", "PhysicalDisk", @("Disk Read Bytes/sec","Disk Write Bytes/sec"), 13, '#,#', 0.000001, 'Sum', $true))
$c.Add([CounterColumn]::new("Read", "PhysicalDisk", @("Disk Read Bytes/sec"), 8, '#,#', 0.000001, 'Sum',  $false))
$c.Add([CounterColumn]::new("Write", "PhysicalDisk", @("Disk Write Bytes/sec"), 8, '#,#', 0.000001, 'Sum', $false))

$c.Add([CounterColumn]::new("Read Lat (ms)", "PhysicalDisk", @("Avg. Disk sec/Read"), 15, '0.000', 1000, 'Average', $true))
$c.Add([CounterColumn]::new("Write Lat", "PhysicalDisk", @("Avg. Disk sec/Write"), 15, '0.000', 1000, 'Average', $false))

$c.Seal()
$allctrs += $c

##
$ctrs = $allctrs |? { $sets[0] -eq '*' -or $sets -contains $_.name }

function start-sample(
    [CounterColumnSet[]] $ctrs,
    [int] $SampleInterval
    )
{
    # clear any previous job instance
    Get-Job -Name watch-cluster -ErrorAction SilentlyContinue | Stop-Job
    Get-Job -Name watch-cluster -ErrorAction SilentlyContinue | Remove-Job

    # flatten list of counters and uniquify for the total counter set
    # some display counter sets may repeat specific values (which is fine)
    $counters = ($ctrs.counters |% { $_ |% { $_ }} | group -NoElement).Name

    icm -AsJob -ThrottleLimit 100 -JobName watch-cluster (Get-ClusterNode) {

        # extract countersamples, the object does not survive transfer between powershell sessions
        # extract as a list, not as the individual counters
        get-counter -Continuous -SampleInterval $using:SampleInterval $using:ctrs.counters |% {
            ,$_.countersamples
        }
    }
}

# start the first sample job and allow frame draw the first time through
$j = start-sample $ctrs $SampleInterval
$downtime = $null
$skipone = $false

# hash of most recent samples/node
$samples = @{}
Get-ClusterNode |% { $samples[$_.Name] = $null }
$my_nodes = Get-ClusterNode | Where-Object Name -Match "^node-\d{1,2}$"

while ($true) {

    sleep -Seconds $SampleInterval

    # sleep again if needed to prime the sample pipeline;
    # there are no samples if we just restarted the sampling jobs
    if ($skipone) {
        $skipone = $false
        continue
    }

    # receive updates into the per-node hash
    foreach ($child in $j.ChildJobs) {
        $samples[$child.Location] = $child | receive-job -ErrorAction SilentlyContinue
    }

    $my_samples = @{}
    foreach($key in $samples.Keys) {
        if($key -match 'node-\d{1,2}$'){
            $my_samples[$key] = $samples[$key]
        }
    }

    # null out downed nodes and remember first time we saw one drop out
    $down = 0
    $j.ChildJobs |? State -ne Running |% {
        $samples[$_.Location] = $null
        $down += 1
    }

    if ($down -and $downtime -eq $null) {
        $downtime = get-date
    }

    $downnow = $false
    if ($down -eq $j.ChildJobs.Count) {
        $downnow = $true
    }

    # if everything is down, or it has been 30 seconds with a downed node, restart the jobs to retry
    if ($downnow -or ($downtime -ne $null -and ((get-date)-$downtime).totalseconds -gt 30)) {
        $j | stop-job
        $j | remove-job
        $j = start-sample $query $SampleInterval
        $downtime = $null
        $skipone = $true
    }

    # now process samples into per-node hashes of set/ctr containing lists of the
    # cooked values acrosss the (possible) multiple instances
    $psamples = @{}
    $my_psamples = @{}

    foreach ($nodes in $my_nodes) {
        $group_nodes =(Get-ClusterNode | Where-Object Name -Match "$nodes$|$nodes-vm-").Name
        $my_nsamples = @{}
        foreach ($group_node in $group_nodes){
            $nsamples = @{}
            $samples[$group_node] |% { $_ } |% {
                ($setinst,$ctr) = $($_.path -split '\\')[3..4]
                $set = ($setinst -split '\(')[0]

                $k = "$set+$ctr"
                $nsamples[$k] = $_.cookedvalue
            }
            if ($my_nsamples.Count -eq 0){
                $my_nsamples = $nsamples
            }
            else {
                foreach($ns in $nsamples.Keys){
                 $my_nsamples[$ns] = $my_nsamples[$ns] + $nsamples[$ns]   
                }
            }
        }
        $my_nsamples["physicaldisk+avg. disk sec/read"] = $my_nsamples["physicaldisk+avg. disk sec/read"] * 40
        $my_nsamples["physicaldisk+avg. disk sec/write"] = $my_nsamples["physicaldisk+avg. disk sec/write"] * 40
        $my_psamples[$nodes.Name] = $my_nsamples 
    }


    # post-process the samples into the counterset, then clear and dump
    #$ctrs.DisplayPre($samples, $psamples)
    $ctrs.DisplayPre($my_samples, $my_psamples)
    cls
    $drawsep = $false
    $ctrs |% {
        if ($drawsep) {
            write-host -fore Green $('-'*20)
        }
        $drawsep = $true
        $_.Display()

    }
}