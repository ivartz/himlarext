: '
* Stats from Nova (up to --os-compute-api-version 2.87).

This is used by python-novaclient in himlarcli to generate the view on hypervisor.py list --format table

openstack hypervisor stats show

+----------------------+---------+
| Field                | Value   |
+----------------------+---------+
| count                | 4       |
| current_workload     | 0       |
| disk_available_least | 10890   |
| free_disk_gb         | 542400  |
| free_ram_mb          | 1418273 |
| local_gb             | 542860  |
| local_gb_used        | 460     |
| memory_mb            | 1545249 |
| memory_mb_used       | 126976  |
| running_vms          | 39      |
| vcpus                | 188     |
| vcpus_used           | 43      |
+----------------------+---------+

code in himlarcli hypervisor.py list

For each hypervisor, query:

NAME
AGGREGATES
VMs : 
vCPUs : host.vcpus_used / host.vcpus
MEMORY (GiB) : int(host.memory_mb_used/1024) / int(host.memory_mb/1024)
DISK (GB) : host.local_gb_used / host.local_gb
STATE
STATUS

Test:

Last supported API version:
openstack --os-compute-api-version 2.87 hypervisor stats show

Newer API version gives:
versions supported by client: 2.1 - 2.87

from

openstack --os-compute-api-version 2.88 hypervisor stats show

* Stats from Placement

The resources that can be queried from placement:

openstack --os-placement-api-version 1.2 resource class list

+----------------------------+
| name                       |
+----------------------------+
| VCPU                       |
| MEMORY_MB                  |
| DISK_GB                    |
| PCI_DEVICE                 |
| SRIOV_NET_VF               |
| NUMA_SOCKET                |
| NUMA_CORE                  |
| NUMA_THREAD                |
| NUMA_MEMORY_MB             |
| IPV4_ADDRESS               |
| VGPU                       |
| VGPU_DISPLAY_HEAD          |
| NET_BW_EGR_KILOBIT_PER_SEC |
| NET_BW_IGR_KILOBIT_PER_SEC |
| PCPU                       |
| MEM_ENCRYPTION_CONTEXT     |
| FPGA                       |
| PGPU                       |
+----------------------------+

Resource provider = Hypervisor

Get resource provider uuids
'
readarray -t resource_providers < <(openstack resource provider list -f value --sort-column name)

declare -A usage_reports

num_resource_providers=${#resource_providers[*]}

# Query resource usage in parallel
for ((i=0;i<$num_resource_providers;++i))
do
  resource_provider=${resource_providers[$i]}
  uuid=$(echo $resource_provider | cut -d ' ' -f 1)

  nohup openstack resource provider usage show $uuid -f value > nohup_$(printf %03d $(($i+1))).stdout 2> /dev/null &
  pids[$i]=$!

  # Prevent parallel execution
  name=$(echo $resource_provider | cut -d ' ' -f 2)
  name=${name%.*.*.*.*} # Remove the rest of the URI
  pid=${pids[$i]}
  echo "querying $name"
  wait $pid

done

# Wait for queries to finish and collect results
for ((i=0;i<$num_resource_providers;++i))
do
  resource_provider=${resource_providers[$i]}
  pid=${pids[$i]}
  wait $pid
  name=$(echo $resource_provider | cut -d ' ' -f 2)
  results_file=nohup_$(printf %03d $(($i+1))).stdout
  usage_reports[$name]=$results_file
done

# Print header
columns=('NAME' 'AGGREGATES' 'VMs' 'vCPUs' 'vGPUs' 'MEMORY (GiB)' 'DISK (GB)' 'STATE' 'STATUS')
resource_strs=(${!usage_reports[*]})
# -> Pick the longest resource string in order to align header correctly
resource_longest_str=''
for s in "${resource_strs[@]}"
do
  s=${s%.*.*.*.*} # Remove the rest of the URI
  if [ ${#s} -gt ${#resource_longest_str} ]
  then
    resource_longest_str="$s"
  fi
done
name_str=${columns[0]}
n=$((${#resource_longest_str}-${#name_str}))
printf "$name_str"
printf '%*s' $n
printf '\t'
for column in "${columns[@]:1}"
do
  printf '%s\t' "$column"
done
printf '\n'

# Report usage
for ((i=0;i<$num_resource_providers;++i))
do
  resource_provider=${resource_providers[$i]}
  key=$(echo $resource_provider | cut -d ' ' -f 2)
  value=${usage_reports[$key]}

  for column in "${columns[@]}"
  do
    if [[ $column == 'NAME' ]]
    then
      name=${key%.*.*.*.*} # Remove the rest of the URI
      n=$((${#resource_longest_str}-${#name}))
      printf '%s' $name
      printf '%*s' $n
      printf '\t'
    elif [[ $column == 'vCPUs' ]]
    then
      VCPU=$(cat $value | grep VCPU | cut -d ' ' -f 2)
      if [ -z $VCPU ]
      then
        VCPU='-'
      fi
      n=$((${#column}-${#VCPU}))
      printf '%s' $VCPU
      printf '%*s' $n
      printf '\t'
    elif [[ $column == 'vGPUs' ]]
    then
      VGPU=$(cat $value | grep VGPU | cut -d ' ' -f 2)
      if [ -z $VGPU ]
      then
        VGPU='-'
      fi
      n=$((${#column}-${#VCPU}))
      printf '%s' $VGPU
      printf '%*s' $n
      printf '\t'
    elif [[ $column == 'MEMORY (GiB)' ]]
    then
      MEMORY_MB=$(cat $value | grep MEMORY_MB | cut -d ' ' -f 2)
      if [ -z $MEMORY_MB ]
      then
        MEMORY_GB='-'
      else
        MEMORY_GB=$(($MEMORY_MB/1024))
      fi
      n=$((${#column}-${#MEMORY_GB}))
      printf '%s' $MEMORY_GB
      printf '%*s' $n
      printf '\t'
    elif [[ $column == 'DISK (GB)' ]]
    then
      DISK_GB=$(cat $value | grep DISK_GB | cut -d ' ' -f 2)
      if [ -z $DISK_GB ]
      then
        DISK_GB='-'
      fi
      n=$((${#column}-${#DISK_GB}))
      printf '%s' $DISK_GB
      printf '%*s' $n
      printf '\t'
    else
      # Not yet implemented
      placeholder='-'
      n=$((${#column}-${#placeholder}))
      printf '%s' $placeholder
      printf '%*s' $n
      printf '\t'
    fi
  done
  printf '\n'
  # Remove temporary file
  rm $value
done

# Get resource usage for specific project and user
#openstack resource usage show
