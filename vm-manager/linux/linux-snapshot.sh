#!/usr/bin/sh

set -e

getInstanceMetadata()
{
    KEY=$1
    curl -s -H "Metadata-Flavor: Google" "http://metadata/computeMetadata/v1/instance/$KEY"
}

getVmName()
{
    getInstanceMetadata name
}

getZone()
{
    zone=$(getInstanceMetadata zone)
    echo "$zone" | sed 's/.*\(zones\/\)\(europe-west4-a\).*/\2/'
}

getPatchJobId()
{
    VM=$1
    ZONE=$2

    # Get running patch jobs
    jobs=$(gcloud compute os-config patch-jobs list --filter="state:patching" --format="value(ID)")

    # Iterating all jobs
    for job in $jobs; do
        # Check if this instance is targetted by the patch job
        # and the job is in the RUNNING_PRE_PATCH_STEP
        filter="name:$VM AND zone:$ZONE AND state:RUNNING_PRE_PATCH_STEP"
        instance=$(gcloud compute os-config patch-jobs list-instance-details "$job" --filter="$filter" --format="value(NAME)")
        if [ "$instance" = "$VM" ]; then
            echo "$job"
            return;
        fi
    done

    echo -1
}

getDisks()
{
    VM=$1
    ZONE=$2

    gcloud compute instances describe "$VM" --zone "$ZONE" --format="value[delimiter=\n](disks[].source)"
}

newSnapshot()
{
    DISKS=$1
    VM=$2
    JOBID=$3
    ZONE=$4
    TDATE=$(date "+%d%m%Y")
    diskNames=$(gcloud compute instances describe "$VM" --zone "$ZONE" | sed -n 's/.*source: .*\/disks\/\([^\/]*\).*/\1/p')

       #create snapshot for disks
    for diskName in $diskNames; do
        snapshot_name="${diskName}-${TDATE}"

        gcloud compute disks snapshot "$diskName" \
            --description="snapshot before patching" \
            --labels reason=patching,patchjob="$JOBID",vm="$VM" \
            --user-output-enabled false \
            --snapshot-names="$snapshot_name" \
            --zone "$ZONE"
    done

    echo 0
}

vmName=$(getVmName)
zone=$(getZone)

echo -n "Determining patch job: "
jobId=$(getPatchJobId "$vmName" "$zone")
echo "$jobId"

echo -n "Retrieving disks associated with VM: "
disks=$(getDisks "$vmName" "$zone")
diskCount=$(echo "$disks" | wc -w)
echo "$diskCount disk(s) found"

if [ "$diskCount" -eq 0 ]; then
    echo "No disks found for VM $vmName in zone $zone."
    exit 1
fi

echo -n "Creating Snapshot(s): "
result=$(newSnapshot "$disks" "$vmName" "$jobId" "$zone")

if [ "$result" -eq 0 ]; then
    echo "done"
else
    echo "failed"
    exit 1
fi

